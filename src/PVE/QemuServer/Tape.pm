package PVE::QemuServer::Tape;

# Channel-attached tape drives of s390x VMs (the 3590-ccw device of QEMU builds with mainframe
# support), with an AWSTAPE image as removable medium. Mainframe operating systems are installed
# from tape: a tape drive can be the IPL device. Media are read-only unless the drive is configured
# writable ('rw'), and can be changed while the VM runs, like a CD-ROM (in the same mode).
#
# Tape media live in the ISO images content of a storage, not with the disks of a VM: they are
# shared media, moved between VMs. A writable medium grows as the guest writes, so it must be a
# file. An empty file is a blank (scratch) tape.

use strict;
use warnings;

use JSON;

use PVE::Cluster;
use PVE::INotify;
use PVE::JSONSchema qw(parse_property_string print_property_string);
use PVE::GuestImport;
use PVE::Storage;

use PVE::QemuServer::Drive;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);

our $MAX_TAPE_DRIVES = 4;

# Device numbers of the tape drives: the conventional 0580 and up, unless configured.
my $DEFAULT_DEVNO_BASE = 0x0580;

PVE::JSONSchema::register_format('pve-qm-tape-file', \&verify_tape_file);

sub verify_tape_file {
    my ($value, $noerr) = @_;

    return $value if $value eq 'none';
    return PVE::QemuServer::Drive::verify_volume_id_or_absolute_path($value, $noerr);
}

my $tape_fmt = {
    file => {
        default_key => 1,
        type => 'string',
        format => 'pve-qm-tape-file',
        format_description => 'volume',
        description => "The tape image (AWSTAPE) in the tape drive, an ISO images volume like"
            . " 'local:iso/install.aws', or 'none' for an empty drive.",
    },
    devno => {
        type => 'string',
        pattern => '(?:0\.[0-3]\.[0-9a-fA-F]{1,4}|[0-9a-fA-F]{3,4})',
        optional => 1,
        format_description => '0.<ssid>.<devno>',
        description => "The device number of the tape drive as the guest sees it, for example"
            . " '0.0.0580'. Defaults to 0.0.0580 for tape0, 0.0.0581 for tape1 and so on.",
    },
    'import-from' => {
        type => 'string',
        format => 'pve-volume-id',
        format_description => 'source volume',
        optional => 1,
        description => "Only when creating or changing the drive: import the medium from a tape"
            . " image (AWSTAPE) in an OVA, '<storage>:import/<name>.ova/<file>.aws', into the ISO"
            . " images content of the storage given as medium '<storage>:0'.",
    },
    ident => {
        type => 'string',
        enum => [qw(3410 3411 3420 3422 3430 3480 3490 3590 8809 9347 9348)],
        optional => 1,
        default => '3590',
        description => "The tape drive type reported to the guest. Some guests select their tape"
            . " driver by it. The commands are the ones of a 3590 in any case.",
    },
    rw => {
        type => 'boolean',
        optional => 1,
        default => 0,
        description => "Whether the guest can write to the medium. Writable media must be tape"
            . " images in the ISO images content of a storage (or files).",
    },
    capacity => {
        type => 'string',
        format => 'disk-size',
        format_description => 'DiskSize',
        optional => 1,
        description => "The capacity of a volume, in bytes of AWS data (with suffix K, M, G or T)."
            . " Default: the largest volume the drive can address.",
    },
    'max-blocks' => {
        type => 'integer',
        minimum => 1,
        maximum => 4294967295,
        optional => 1,
        description => "The maximum number of blocks and tape marks on a volume. Default: what the"
            . " block ID of the drive type can address (2^32-1, or 2^22-1 for 3480 and 3490).",
    },
    'eot-margin' => {
        type => 'string',
        format => 'disk-size',
        format_description => 'DiskSize',
        optional => 1,
        description => "The distance of the logical end of tape (the early warning) from the end of"
            . " a volume, in bytes (with suffix K, M, G or T).",
    },
    'eot-margin-blocks' => {
        type => 'integer',
        minimum => 0,
        maximum => 4294967295,
        optional => 1,
        description => "The distance of the logical end of tape from the end of a volume, in"
            . " blocks.",
    },
};

# Device properties of the drive, passed only when set. Changing them needs a restart.
my $device_properties = [qw(ident capacity max-blocks eot-margin eot-margin-blocks)];
PVE::JSONSchema::register_format('pve-qm-tape', $tape_fmt);

our $tape_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-tape',
    description => "A tape drive of an s390x VM (needs a QEMU build with the 3590-ccw device),"
        . " with an AWSTAPE image as medium, read-only unless 'rw' is set.",
};

sub valid_tape_keys {
    return map { "tape$_" } (0 .. $MAX_TAPE_DRIVES - 1);
}

sub is_tape_key {
    my ($key) = @_;
    return $key =~ m/^tape(\d+)$/ && $1 < $MAX_TAPE_DRIVES;
}

sub parse_tape {
    my ($value) = @_;
    return parse_property_string($tape_fmt, $value);
}

sub print_tape {
    my ($tape) = @_;
    return print_property_string($tape, $tape_fmt);
}

# The CCW device number of a tape drive, in the 'fe.<ssid>.<devno>' form QEMU uses (the guest sees
# channel subsystem 0xfe as 0).
sub get_devno {
    my ($key, $tape) = @_;

    my ($index) = $key =~ m/^tape(\d+)$/;
    my ($ssid, $devno) = (0, $DEFAULT_DEVNO_BASE + $index);
    if (defined(my $value = $tape->{devno})) {
        ($ssid, $devno) = $value =~ m/^0\.([0-3])\.([0-9a-f]+)$/i ? ($1, hex($2)) : (0, hex($value));
    }
    return sprintf('fe.%x.%04x', $ssid, $devno);
}

# The tape drives of a config, as [key, parsed value] sorted by key. Dies on duplicate device
# numbers.
sub get_tapes {
    my ($conf) = @_;

    my $res = [];
    my $devnos = {};
    my $media = {};
    for my $key (valid_tape_keys()) {
        next if !$conf->{$key};
        my $tape = parse_tape($conf->{$key});
        my $devno = get_devno($key, $tape);
        die "$key: device number $devno is already used by $devnos->{$devno}\n"
            if $devnos->{$devno};
        $devnos->{$devno} = $key;
        my $file = $tape->{file};
        if ($file ne 'none') {
            if (my $other = $media->{$file}) {
                die "$key: the medium '$file' is in $other->[0] too, a writable medium can only be"
                    . " in one drive\n"
                    if $tape->{rw} || $other->[1];
            }
            $media->{$file} = [$key, $tape->{rw}];
        }
        push @$res, [$key, $tape];
    }

    return $res;
}

=head3 assert_writable_medium($storecfg, $key, $tape)

Dies if the medium of the tape drive C<$key> with the parsed value C<$tape> is writable but cannot
be: writable media are tape images in the ISO images content of a storage, or files given by
path, because they grow as the guest writes.

=cut

sub assert_writable_medium {
    my ($storecfg, $key, $tape) = @_;

    return if !$tape->{rw};
    my $file = $tape->{file};
    return if $file eq 'none';

    my $path = $file;
    if ($file !~ m|^/|) {
        my ($vtype) = PVE::Storage::parse_volname($storecfg, $file);
        die "$key: only tape images in the ISO images content of a storage can be writable,"
            . " not '$file'\n"
            if $vtype ne 'iso';
        $path = PVE::Storage::path($storecfg, $file);
    }
    die "$key: '$path' is not a file, a writable tape medium must be one\n"
        if -e $path && !-f $path;
    return;
}

=head3 check_config($storecfg, $conf)

Check the tape drives of C<$conf>: device numbers, media in several drives and writable media.

=cut

sub check_config {
    my ($storecfg, $conf) = @_;

    for my $entry (get_tapes($conf)->@*) {
        my ($key, $tape) = @$entry;
        # media imported from an OVA are checked after the import
        next if defined($tape->{'import-from'});
        assert_writable_medium($storecfg, $key, $tape);
    }
    return;
}

my sub import_target_storage {
    my ($tape) = @_;
    return $tape->{file} =~ m/^([^:\/]+):0$/ ? $1 : undef;
}

=head3 media_imports($param)

The tape drives of the parameters C<$param> of a VM creation or change whose medium is imported
from an OVA (option 'import-from'), as list of C<[$key, $source, $storeid]>. Dies if the target is
not given as '<storage>:0'.

=cut

sub media_imports {
    my ($param) = @_;

    my $res = [];
    for my $key (valid_tape_keys()) {
        next if !defined($param->{$key});
        my $tape = parse_tape($param->{$key});
        next if !defined($tape->{'import-from'});
        my $storeid = import_target_storage($tape)
            or die "$key: give the storage for the imported medium as '<storage>:0'\n";
        push @$res, [$key, $tape->{'import-from'}, $storeid];
    }
    return $res;
}

=head3 import_media($param)

Import the media of the tape drives in the parameters C<$param> that have 'import-from' into the
ISO images content of their storage, and replace the values with the imported media.

=cut

sub import_media {
    my ($param) = @_;

    for my $import (media_imports($param)->@*) {
        my ($key, $source, $storeid) = @$import;
        my $tape = parse_tape($param->{$key});
        print "$key: importing medium '$source' to storage '$storeid'\n";
        $tape->{file} = PVE::GuestImport::extract_media_from_import_file($source, $storeid);
        delete $tape->{'import-from'};
        $param->{$key} = print_tape($tape);
    }
    return;
}

# The volumes of the tape media of a config, for activation.
sub get_volumes {
    my ($conf) = @_;

    my $res = [];
    for my $key (valid_tape_keys()) {
        next if !$conf->{$key};
        my $tape = eval { parse_tape($conf->{$key}) } or next;
        my $file = $tape->{file};
        next if $file eq 'none' || $file =~ m|^/|;
        push @$res, $file;
    }
    return $res;
}

my sub tape_path {
    my ($storecfg, $file) = @_;

    return undef if $file eq 'none';
    return $file if $file =~ m|^/|;
    return PVE::Storage::path($storecfg, $file);
}

=head3 check_media_in_use($storecfg, $vmid, $conf)

Dies if a medium in the tape drives of the VM C<$vmid> with config C<$conf> is writable and in a
tape drive of another VM running on this node, or is writable there. Other nodes are not checked:
a medium on shared storage must not be written by VMs on two nodes.

=cut

sub check_media_in_use {
    my ($storecfg, $vmid, $conf) = @_;

    my $wanted = {};
    for my $entry (get_tapes($conf)->@*) {
        my ($key, $tape) = @$entry;
        my $path = eval { tape_path($storecfg, $tape->{file}) } // next;
        $wanted->{$path} = [$key, $tape->{rw}];
    }
    return if !%$wanted;

    my $nodename = PVE::INotify::nodename();
    my $ids = (PVE::Cluster::get_vmlist() // {})->{ids} // {};
    for my $other (sort { $a <=> $b } keys %$ids) {
        next if $other == $vmid;
        my $info = $ids->{$other};
        next if ($info->{type} // '') ne 'qemu' || ($info->{node} // '') ne $nodename;
        next if !PVE::QemuServer::Helpers::vm_running_locally($other);
        my $other_conf = eval { PVE::QemuConfig->load_config($other) } or next;
        for my $other_key (valid_tape_keys()) {
            next if !$other_conf->{$other_key};
            my $other_tape = eval { parse_tape($other_conf->{$other_key}) } or next;
            my $path = eval { tape_path($storecfg, $other_tape->{file}) } // next;
            my $mine = $wanted->{$path} or next;
            die "$mine->[0]: the medium '$path' is loaded writable in $other_key of the running VM"
                . " $other\n"
                if $other_tape->{rw};
            die "$mine->[0]: the medium '$path' is loaded in $other_key of the running VM $other,"
                . " it cannot be loaded writable\n"
                if $mine->[1];
        }
    }
    return;
}

# The QEMU arguments for the tape drives of a config.
sub get_command_args {
    my ($storecfg, $conf, $arch, $kvm_binary) = @_;

    my $tapes = get_tapes($conf);
    return [] if !@$tapes;

    die "tape drives are only supported on s390x\n" if $arch ne 's390x';
    die "the installed QEMU has no tape drive (3590-ccw)\n"
        if !PVE::QemuServer::Helpers::kvm_device_types($kvm_binary)->{'3590-ccw'};

    my $args = [];
    for my $entry (@$tapes) {
        my ($key, $tape) = @$entry;
        die "$key: 'import-from' is only for creating or changing the tape drive\n"
            if defined($tape->{'import-from'});
        assert_writable_medium($storecfg, $key, $tape);
        # Also an empty drive gets its block backend, writable or not like the media it takes: the
        # drive keeps the permissions it starts with.
        my $drive = "if=none,id=drive-$key";
        if (defined(my $path = tape_path($storecfg, $tape->{file}))) {
            $path =~ s/,/,,/g;
            $drive .= ",file=$path,format=raw";
        }
        $drive .= ",read-only=on" if !$tape->{rw};
        push @$args, '-drive', $drive;
        my $device = "3590-ccw,id=$key,devno=" . get_devno($key, $tape) . ",drive=drive-$key";
        for my $opt ($device_properties->@*) {
            next if !defined(my $value = $tape->{$opt});
            # sizes in bytes, QEMU does not know all the suffixes of 'disk-size'
            $value = PVE::JSONSchema::parse_size($value) if $tape_fmt->{$opt}->{format}
                && $tape_fmt->{$opt}->{format} eq 'disk-size';
            $device .= ",$opt=$value";
        }
        push @$args, '-device', $device;
    }

    return $args;
}

my sub drive_unloaded {
    my ($vmid, $key) = @_;

    for my $block (mon_cmd($vmid, 'query-block')->@*) {
        next if ($block->{device} // '') ne "drive-$key";
        return !$block->{inserted} || $block->{tray_open};
    }
    return 1;
}

=head3 change_medium($storecfg, $vmid, $conf, $key, $old_value, $new_value)

Change the medium of the tape drive C<$key> of the running VM C<$vmid> with config C<$conf>: the
drive unloads the old medium and loads the new one, which raises device attention in the guest.
The same medium is loaded again if the guest unloaded it (Rewind Unload). Returns 0 if anything
else changed, that needs a restart.

=cut

sub change_medium {
    my ($storecfg, $vmid, $conf, $key, $old_value, $new_value) = @_;

    my $old = parse_tape($old_value);
    my $new = parse_tape($new_value);
    for my $opt ('devno', $device_properties->@*) {
        return 0 if ($old->{$opt} // '') ne ($new->{$opt} // '');
    }
    # The drive keeps the write permission it started with: a writable medium in a drive started
    # read-only would be write-protected, a read-only one cannot go into a drive started writable.
    return 0 if !$old->{rw} != !$new->{rw};
    if ($old->{file} eq $new->{file}) {
        return 1 if $new->{file} eq 'none' || !drive_unloaded($vmid, $key);
    }

    assert_writable_medium($storecfg, $key, $new);
    check_media_in_use($storecfg, $vmid, { $conf->%*, $key => $new_value });

    mon_cmd($vmid, 'eject', id => $key, force => JSON::true);
    if (defined(my $path = tape_path($storecfg, $new->{file}))) {
        PVE::Storage::activate_volumes($storecfg, [$new->{file}]) if $new->{file} !~ m|^/|;
        mon_cmd(
            $vmid, 'blockdev-change-medium',
            id => $key,
            filename => $path,
            format => 'raw',
            'read-only-mode' => $new->{rw} ? 'read-write' : 'read-only',
        );
    }

    return 1;
}

=head3 drive_states($storecfg, $vmid, $conf)

The state of the tape drives of the running VM C<$vmid> with config C<$conf>, as hash tape drive
key => C<{ loaded, file, 'read-only', medium }>: whether a medium is loaded (not when the drive is
empty or the guest unloaded it, e.g. with Rewind Unload), the file of the medium in the drive, if
it is read-only, and the configured medium if the file is that one. C<undef> without tape drives.

=cut

sub drive_states {
    my ($storecfg, $vmid, $conf) = @_;

    my $configured = {};
    for my $key (valid_tape_keys()) {
        next if !$conf->{$key};
        my $tape = eval { parse_tape($conf->{$key}) } or next;
        $configured->{$key} = $tape->{file};
    }
    return undef if !%$configured;

    my $res = {};
    for my $block (mon_cmd($vmid, 'query-block')->@*) {
        my ($key) = ($block->{device} // '') =~ m/^drive-(tape\d+)$/ or next;
        next if !exists($configured->{$key});
        my $inserted = $block->{inserted};
        my $state = { loaded => ($inserted && !$block->{tray_open}) ? 1 : 0 };
        if ($inserted) {
            $state->{file} = $inserted->{file};
            $state->{'read-only'} = $inserted->{ro} ? 1 : 0;
            my $path = eval { tape_path($storecfg, $configured->{$key}) };
            $state->{medium} = $configured->{$key} if defined($path) && $path eq $inserted->{file};
        }
        $res->{$key} = $state;
    }
    return $res;
}

=head3 writable_media($conf)

The keys of the tape drives of C<$conf> with a writable medium loaded.

=cut

sub writable_media {
    my ($conf) = @_;

    my $res = [];
    for my $key (valid_tape_keys()) {
        next if !$conf->{$key};
        my $tape = eval { parse_tape($conf->{$key}) } or next;
        push @$res, $key if $tape->{rw} && $tape->{file} ne 'none';
    }
    return $res;
}

1;
