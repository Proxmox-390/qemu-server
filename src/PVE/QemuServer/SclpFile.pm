package PVE::QemuServer::SclpFile;

# Shared folder of s390x VMs with SCLP file access: the files below one directory of the node are
# served to the guest by name through SCLP, as the HMC or SE does for the media a system is loaded
# from. Installers of mainframe operating systems are loaded from an .ins file in the folder (see
# the 'ipl' option) and read the rest of their media this way; Linux uses it as the HMC drive
# (hmcdrv). The directory is a directory mapping, like for virtiofs.

use strict;
use warnings;

use Cwd;

use PVE::JSONSchema qw(parse_property_string);
use PVE::Mapping::Dir;

use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);

# the ID of the QEMU device
my $DEVICE_ID = 'sclpfile';

# The .ins files of a folder offered for the IPL: at most this many, of at most this many
# directory entries read.
my $MAX_INS_FILES = 256;
my $MAX_DIR_ENTRIES = 16384;

my $sclpfile_fmt = {
    dirid => {
        type => 'string',
        default_key => 1,
        description =>
            "Mapping identifier of the directory mapping to be shared with the guest.",
        format_description => 'mapping-id',
        format => 'pve-configid',
    },
    readonly => {
        type => 'boolean',
        description => "Whether the guest can only read the files. If disabled, the guest can"
            . " also create, replace, extend and delete files in the directory.",
        default => 1,
        optional => 1,
    },
};
PVE::JSONSchema::register_format('pve-qm-sclpfile', $sclpfile_fmt);

our $sclpfile_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-sclpfile',
    description => "Share a directory with the guest through SCLP file access: the guest reads"
        . " files by name, as from the media a system is loaded from. Used by installers of"
        . " mainframe operating systems, and by Linux (HMC drive). Only for s390x VMs. To load"
        . " an installer from the directory, see 'ipl'.",
};

# The pattern of the 'file' property of the 'ipl' option, see assert_ins_file_name() for the
# checks with a message.
our $INS_FILE_NAME_PATTERN = '[^\s,;]+';

sub parse_sclpfile {
    my ($value) = @_;
    return parse_property_string($sclpfile_fmt, $value);
}

sub is_readonly {
    my ($sclpfile) = @_;
    return $sclpfile->{readonly} // 1;
}

# Whether a file exists, apart for mocking in tests.
sub file_exists {
    my ($path) = @_;
    return -f $path;
}

# The directory of the node that the 'sclpfile' value shares, checked to exist.
sub get_directory {
    my ($sclpfile) = @_;

    my $dir_cfg = PVE::Mapping::Dir::find_on_current_node($sclpfile->{dirid});
    eval { PVE::Mapping::Dir::assert_valid($dir_cfg) };
    die "sclpfile: directory mapping invalid: $@" if $@;

    return $dir_cfg->{path};
}

# The QEMU arguments for the shared folder of a VM config.
sub get_command_args {
    my ($conf, $arch, $kvm_binary) = @_;

    return [] if !$conf->{sclpfile};

    die "sclpfile: only supported on s390x\n" if $arch ne 's390x';
    my $sclpfile = parse_sclpfile($conf->{sclpfile});
    die "the installed QEMU has no SCLP file access (sclpfileaccess)\n"
        if !PVE::QemuServer::Helpers::kvm_device_types($kvm_binary)->{sclpfileaccess};

    my $path = get_directory($sclpfile);
    $path =~ s/,/,,/g;
    my $device = "sclpfileaccess,id=$DEVICE_ID,path=$path";
    $device .= ",readonly=off" if !is_readonly($sclpfile);

    return ['-device', $device];
}

# Check the name of the file to IPL from: a file in the top directory of the shared folder.
sub assert_ins_file_name {
    my ($file) = @_;

    die "ipl: file '$file' must be a file in the top directory of the shared folder, without '/'\n"
        if $file =~ m|/|;
    die "ipl: file '$file' is not an .ins file\n" if $file !~ m/.\.ins$/i;

    return $file;
}

# The path on the node of the .ins file to IPL from, which has to exist.
sub get_ins_file_path {
    my ($conf, $file) = @_;

    die "ipl: no shared folder with SCLP file access ('sclpfile') to load '$file' from\n"
        if !$conf->{sclpfile};
    assert_ins_file_name($file);

    my $sclpfile = parse_sclpfile($conf->{sclpfile});
    my $path = get_directory($sclpfile) . "/$file";
    die "ipl: file '$file' does not exist in the shared folder '$sclpfile->{dirid}'\n"
        if !file_exists($path);

    return $path;
}

# The names of the .ins files in the top directory of a directory, sorted. Symbolic links count
# if they point to a file below the directory, as for the guest. Returns the first
# $MAX_INS_FILES names only, and looks at $MAX_DIR_ENTRIES directory entries at most.
sub list_ins_files {
    my ($dir) = @_;

    my $real_dir = Cwd::realpath($dir);
    return [] if !defined($real_dir) || !-d $real_dir;

    opendir(my $dh, $real_dir) or die "unable to read directory '$dir' - $!\n";
    my $names = [];
    my $seen = 0;
    while (defined(my $name = readdir($dh))) {
        last if ++$seen > $MAX_DIR_ENTRIES;
        next if $name !~ m/^$INS_FILE_NAME_PATTERN$/ || $name !~ m/.\.ins$/i;
        my $path = "$real_dir/$name";
        if (-l $path) {
            my $target = Cwd::realpath($path);
            next if !defined($target) || index($target, "$real_dir/") != 0;
            $path = $target;
        }
        push @$names, $name if -f $path;
    }
    closedir($dh);

    my @sorted = sort @$names;
    splice(@sorted, $MAX_INS_FILES) if @sorted > $MAX_INS_FILES;

    return \@sorted;
}

# The .ins files of the shared folder of a VM config on this node, see list_ins_files().
sub get_ins_files {
    my ($conf) = @_;

    return [] if !$conf->{sclpfile};
    return list_ins_files(get_directory(parse_sclpfile($conf->{sclpfile})));
}

# Give the device of a running VM another directory, for a change from the 'sclpfile' value $old
# to $new. Returns false if the change needs more than that, i.e. a restart.
sub change_directory {
    my ($vmid, $old, $new) = @_;

    my $old_sclpfile = parse_sclpfile($old);
    my $new_sclpfile = parse_sclpfile($new);

    return 0 if is_readonly($old_sclpfile) != is_readonly($new_sclpfile);
    return 1 if $old_sclpfile->{dirid} eq $new_sclpfile->{dirid};

    mon_cmd(
        $vmid,
        'qom-set',
        path => "/machine/peripheral/$DEVICE_ID",
        property => 'path',
        value => get_directory($new_sclpfile),
    );

    return 1;
}

1;
