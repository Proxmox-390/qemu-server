#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::MockModule;
use Test::More;

use PVE::File qw(file_set_contents);
use PVE::QemuServer::Helpers;
use PVE::QemuServer::IPL;
use PVE::QemuServer::SclpFile;

# what QEMU-mod reports, ipl-method of the IPL-capable types
my $qemu_mod_ipl_methods = {
    '3590-ccw' => 'ccw',
    'eckd-ccw' => 'ccw',
    'fba-ccw' => 'ccw',
    'vfio-ccw' => 'ccw',
    'scsi-block' => 'firmware',
    'scsi-cd' => 'firmware',
    'scsi-hd' => 'firmware',
    'virtio-blk-ccw' => 'firmware',
    'virtio-net-ccw' => 'firmware',
};
my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
$helpers->mock(
    kvm_device_ipl_methods => sub {
        my ($binary, $types) = @_;
        return { map { $_ => $qemu_mod_ipl_methods->{$_} // 'none' } @$types };
    },
);

my $format_tests = [
    ['virtio0', { device => 'virtio0' }],
    ['device=net0,loadparm=1', { device => 'net0', loadparm => '1' }],
    ['scsi1,loadparm=0A01M 1', { device => 'scsi1', loadparm => '0A01M 1' }],
    ['virtio0,loadparm=12345678', { device => 'virtio0', loadparm => '12345678' }],
    ['virtio0,loadparm=abc', undef],
    ['virtio0,loadparm=123456789', undef],
    ['virtio0,loadparm=A-B', undef],
    ['loadparm=1', undef],
    ['sclpfile,file=640VM.INS', { device => 'sclpfile', file => '640VM.INS' }],
    [
        'device=sclpfile,file=generic.ins,loadparm=1',
        { device => 'sclpfile', file => 'generic.ins', loadparm => '1' },
    ],
    ['sclpfile', { device => 'sclpfile' }], # 'file' is required by check_ipl_config()
    ['sclpfile,file=two words.ins', undef],
    ['sclpfile,file=', undef],
    ['sclp', undef],
];

for my $test ($format_tests->@*) {
    my ($value, $expected) = $test->@*;
    my $ipl = eval { PVE::QemuServer::IPL::parse_ipl($value) };
    if ($expected) {
        is_deeply($ipl, $expected, "ipl '$value' is valid");
    } else {
        ok(!$ipl && $@, "ipl '$value' is invalid");
    }
}

my $conf = {
    arch => 's390x',
    efidisk0 => 'local:8006/vm-8006-disk-9.qcow2,size=1M',
    ide0 => 'local:8006/vm-8006-disk-8.qcow2,size=8G',
    net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0',
    net1 => 'e1000=BC:24:11:00:00:01,bridge=vmbr0',
    net2 => 'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0400',
    scsi0 => 'local:8006/vm-8006-disk-1.qcow2,size=8G',
    scsi1 => 'local:iso/mf-install.iso,media=cdrom',
    scsi2 => 'local:8006/vm-8006-cloudinit.qcow2,media=cdrom',
    scsihw => 'virtio-scsi-single',
    virtio0 => 'local:8006/vm-8006-disk-0.qcow2,size=8G',
};

is_deeply(
    PVE::QemuServer::IPL::get_ipl_devices($conf, undef, '/usr/bin/kvm'),
    [
        {
            key => 'net0',
            type => 'virtio-net-ccw',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0012',
            description => 'network device BC:24:11:00:00:00, bridge vmbr0',
        },
        {
            key => 'scsi0',
            type => 'scsi-hd',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0061',
            description => 'disk local:8006/vm-8006-disk-1.qcow2',
        },
        {
            key => 'scsi1',
            type => 'scsi-cd',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0062',
            description => 'CD-ROM local:iso/mf-install.iso',
        },
        {
            key => 'virtio0',
            type => 'virtio-blk-ccw',
            'ipl-method' => 'firmware',
            devno => 'fe.0.000a',
            description => 'disk local:8006/vm-8006-disk-0.qcow2',
        },
    ],
    'IPL devices: virtio and SCSI disks and CD-ROMs, virtio NICs; no cloud-init, EFI, IDE, e1000'
        . ' or qeth (QEMU-mod cannot IPL from qeth)',
);

is_deeply(
    PVE::QemuServer::IPL::get_ipl_devices(
        {
            arch => 's390x',
            scsi0 => 'local:8006/vm-8006-disk-1.qcow2,size=8G',
            tape0 => 'local:iso/SYSTEM.AWS',
            tape2 => 'none,devno=0.0.0590',
        },
        undef,
        '/usr/bin/kvm',
    ),
    [
        {
            key => 'scsi0',
            type => 'scsi-hd',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0005',
            description => 'disk local:8006/vm-8006-disk-1.qcow2',
        },
        {
            key => 'tape0',
            type => '3590-ccw',
            'ipl-method' => 'ccw',
            devno => 'fe.0.0580',
            description => 'tape drive, local:iso/SYSTEM.AWS',
        },
        {
            key => 'tape2',
            type => '3590-ccw',
            'ipl-method' => 'ccw',
            devno => 'fe.0.0590',
            description => 'tape drive, empty',
        },
    ],
    'IPL devices: tape drives, also empty ones; virtio SCSI controller by default',
);

{
    local $qemu_mod_ipl_methods->{'qeth-ccw'} = 'ccw';
    my ($qeth) = grep { $_->{key} eq 'net2' }
        PVE::QemuServer::IPL::get_ipl_devices($conf, undef, '/usr/bin/kvm')->@*;
    is_deeply(
        $qeth,
        {
            key => 'net2',
            type => 'qeth-ccw',
            'ipl-method' => 'ccw',
            devno => 'fe.0.0400',
            description => 'network device BC:24:11:00:00:02, bridge vmbr0',
        },
        'a qeth adapter is an IPL device at its configured device number if QEMU can IPL from it',
    );
}

# the shared folder with SCLP file access: an entry without device number
my $folder_conf = {
    arch => 's390x',
    sclpfile => 'share0,readonly=0',
    virtio0 => 'local:8006/vm-8006-disk-0.qcow2,size=8G',
};
my $folder_device = {
    key => 'sclpfile',
    type => 'sclpfileaccess',
    'ipl-method' => 'file',
    description => 'Shared folder (SCLP file access) share0',
};
is_deeply(
    PVE::QemuServer::IPL::get_ipl_devices($folder_conf, undef, '/usr/bin/kvm'),
    [
        $folder_device,
        {
            key => 'virtio0',
            type => 'virtio-blk-ccw',
            'ipl-method' => 'firmware',
            devno => 'fe.0.000a',
            description => 'disk local:8006/vm-8006-disk-0.qcow2',
        },
    ],
    'IPL devices: the shared folder with SCLP file access, when configured',
);
ok(PVE::QemuServer::IPL::ipl_from_file($folder_device), "IPL method 'file' loads an .ins file");
ok(
    !PVE::QemuServer::IPL::ipl_from_file({ 'ipl-method' => 'ccw' })
        && !PVE::QemuServer::IPL::ipl_from_file({ 'ipl-method' => 'firmware' }),
    'IPL from a device does not load an .ins file',
);

my $check_tests = [
    ['sclpfile,file=640VM.INS,loadparm=CONS0009', {}, undef],
    ['sclpfile,file=generic.ins', {}, undef],
    ['virtio0,loadparm=1', {}, undef],
    ['sclpfile', {}, qr/^ipl: 'file' is required to IPL from the shared folder/],
    [
        'sclpfile,file=sub/640VM.INS',
        {},
        qr/^ipl: file 'sub\/640VM\.INS' must be a file in the top/,
    ],
    ['sclpfile,file=../640VM.INS', {}, qr/must be a file in the top directory/],
    ['sclpfile,file=640VM.TXT', {}, qr/^ipl: file '640VM\.TXT' is not an \.ins file/],
    ['sclpfile,file=.ins', {}, qr/^ipl: file '\.ins' is not an \.ins file/],
    ['virtio0,file=640VM.INS', {}, qr/^ipl: 'file' is only for an IPL from the shared folder/],
    [
        'sclpfile,file=640VM.INS',
        { sclpfile => undef },
        qr/^ipl: the VM has no shared folder with SCLP file access \('sclpfile'\)/,
    ],
    ['sclpfile,file=640VM.INS', { arch => 'x86_64' }, qr/^ipl: only supported on s390x/],
];
for my $test ($check_tests->@*) {
    my ($value, $override, $expected) = $test->@*;
    my $test_conf = { $folder_conf->%*, $override->%*, ipl => $value };
    my ($ipl, $device) =
        eval { PVE::QemuServer::IPL::check_ipl_config($test_conf, undef, '/usr/bin/kvm') };
    if ($expected) {
        like($@, $expected, "ipl '$value' is refused");
    } else {
        is($@, '', "ipl '$value' is accepted");
    }
}

ok(
    PVE::QemuServer::IPL::config_ipl_from_file({ ipl => 'sclpfile,file=640VM.INS' }),
    'config with an IPL from the shared folder',
);
ok(
    !PVE::QemuServer::IPL::config_ipl_from_file({ ipl => 'virtio0' })
        && !PVE::QemuServer::IPL::config_ipl_from_file({}),
    'config with an IPL from a device, or without',
);
my $netboot = 'url=https://mirror.example.com/generic.ins,kernel=local:snippets/a.kernel';
eval {
    PVE::QemuServer::IPL::assert_no_netboot_conflict(
        { ipl => 'sclpfile,file=640VM.INS', netboot => $netboot });
};
like(
    $@,
    qr/^netboot: cannot be used together with an IPL from the shared folder/,
    'network boot and IPL from the shared folder exclude each other',
);
eval {
    PVE::QemuServer::IPL::assert_no_netboot_conflict({ ipl => 'virtio0', netboot => $netboot });
    PVE::QemuServer::IPL::assert_no_netboot_conflict({ ipl => 'sclpfile,file=640VM.INS' });
};
is($@, '', 'network boot with an IPL device, and IPL from the shared folder alone');

# the .ins files of a shared folder
{
    my $folder = tempdir(CLEANUP => 1);
    my $outside = tempdir(CLEANUP => 1);
    make_path("$folder/cd1", "$folder/DIR.INS");
    file_set_contents("$folder/$_", "* test\n")
        for qw(640VM.INS generic.ins Mixed.Ins readme.txt ins cd1/SUB.INS cd1/target);
    file_set_contents("$folder/two words.ins", "* test\n");
    file_set_contents("$outside/SECRET.INS", "* test\n");
    symlink('640VM.INS', "$folder/LINK.INS") or die "symlink failed - $!\n";
    symlink('cd1/target', "$folder/SUBLINK.INS") or die "symlink failed - $!\n";
    symlink("$outside/SECRET.INS", "$folder/OUTSIDE.INS") or die "symlink failed - $!\n";
    symlink('nowhere', "$folder/DANGLING.INS") or die "symlink failed - $!\n";
    symlink('cd1', "$folder/DIRLINK.INS") or die "symlink failed - $!\n";

    is_deeply(
        PVE::QemuServer::SclpFile::list_ins_files($folder),
        [qw(640VM.INS LINK.INS Mixed.Ins SUBLINK.INS generic.ins)],
        '.ins files: top directory only, any case, sorted; links only to files below the folder',
    );

    symlink($folder, "$outside/folder") or die "symlink failed - $!\n";
    is_deeply(
        PVE::QemuServer::SclpFile::list_ins_files("$outside/folder"),
        [qw(640VM.INS LINK.INS Mixed.Ins SUBLINK.INS generic.ins)],
        '.ins files: the folder itself may be a link',
    );
    is_deeply(PVE::QemuServer::SclpFile::list_ins_files("$folder/none"), [], 'no directory');
    is_deeply(PVE::QemuServer::SclpFile::list_ins_files("$folder/cd1"), ['SUB.INS'], 'other');

    my $many = tempdir(CLEANUP => 1);
    file_set_contents(sprintf("%s/F%04d.INS", $many, $_), '') for 1 .. 300;
    my $files = PVE::QemuServer::SclpFile::list_ins_files($many);
    is(scalar($files->@*), 256, '.ins files: at most 256 names');
    is_deeply([$files->@[0, 255]], ['F0001.INS', 'F0256.INS'], '.ins files: the first ones');
}

# the QEMU device and the file to load
{
    my $mapping = Test::MockModule->new('PVE::Mapping::Dir');
    my $folder = tempdir(CLEANUP => 1);
    file_set_contents("$folder/640VM.INS", "* test\n");
    $mapping->mock(
        find_on_current_node => sub {
            my ($id) = @_;
            die "Directory ID $id does not exist.\n" if $id !~ m/^share/;
            return { node => 'localhost', path => $id eq 'share1' ? "$folder/gone" : $folder };
        },
    );
    my $device_types = { sclpfileaccess => 1 };
    $helpers->mock(kvm_device_types => sub { return $device_types; });

    my $args = sub {
        my ($conf, $arch) = @_;
        $arch //= 's390x';
        return PVE::QemuServer::SclpFile::get_command_args($conf, $arch, '/usr/bin/kvm');
    };
    is_deeply($args->({}), [], 'no device without the option');
    is_deeply(
        $args->({ sclpfile => 'share0' }),
        ['-device', "sclpfileaccess,id=sclpfile,path=$folder"],
        'device of a read-only shared folder',
    );
    is_deeply(
        $args->({ sclpfile => 'dirid=share0,readonly=0' }),
        ['-device', "sclpfileaccess,id=sclpfile,path=$folder,readonly=off"],
        'device of a writable shared folder',
    );
    eval { $args->({ sclpfile => 'share0' }, 'x86_64') };
    is($@, "sclpfile: only supported on s390x\n", 'shared folder on another architecture');
    eval { $args->({ sclpfile => 'share1' }) };
    like($@, qr/^sclpfile: directory mapping invalid: Path .* does not exist/, 'no directory');
    eval { $args->({ sclpfile => 'other' }) };
    is($@, "Directory ID other does not exist.\n", 'no directory mapping');
    {
        local $device_types->{sclpfileaccess} = 0;
        eval { $args->({ sclpfile => 'share0' }) };
        is(
            $@,
            "the installed QEMU has no SCLP file access (sclpfileaccess)\n",
            'QEMU binary without the device',
        );
    }
    $helpers->unmock('kvm_device_types');

    my $path = sub { PVE::QemuServer::SclpFile::get_ins_file_path(@_) };
    is($path->({ sclpfile => 'share0' }, '640VM.INS'), "$folder/640VM.INS", 'file to load');
    eval { $path->({ sclpfile => 'share0' }, '710VM.INS') };
    is(
        $@,
        "ipl: file '710VM.INS' does not exist in the shared folder 'share0'\n",
        'file to load that does not exist',
    );
    is_deeply(
        PVE::QemuServer::SclpFile::get_ins_files({ sclpfile => 'share0' }),
        ['640VM.INS'],
        '.ins files of the shared folder of a config',
    );
    is_deeply(PVE::QemuServer::SclpFile::get_ins_files({}), [], 'no shared folder, no files');

    # another directory for the device of a running VM
    my @qmp;
    my $monitor = Test::MockModule->new('PVE::QemuServer::SclpFile');
    $monitor->mock(mon_cmd => sub { push @qmp, [@_]; return; });
    my $change = sub { PVE::QemuServer::SclpFile::change_directory(100, @_) };
    ok($change->('share0', 'share2,readonly=1'), 'another directory is applied');
    is_deeply(
        \@qmp,
        [[
            100,
            'qom-set',
            path => '/machine/peripheral/sclpfile',
            property => 'path',
            value => $folder,
        ]],
        'another directory: the path of the device is set',
    );
    @qmp = ();
    ok($change->('share0', 'dirid=share0,readonly=1'), 'same directory and access: applied');
    ok(!$change->('share0', 'share2,readonly=0'), 'readonly needs a restart');
    ok(!$change->('share0,readonly=0', 'share0'), 'readonly needs a restart, also to enable');
    is_deeply(\@qmp, [], 'nothing set otherwise');
    eval { $change->('share0', 'share1') };
    like($@, qr/^sclpfile: directory mapping invalid/, 'another directory that does not exist');
}

ok(
    PVE::QemuServer::IPL::ipl_with_bootindex({ 'ipl-method' => 'firmware' }),
    "IPL method 'firmware' uses bootindex",
);
ok(
    !PVE::QemuServer::IPL::ipl_with_bootindex({ 'ipl-method' => 'ccw' }),
    "IPL method 'ccw' is a channel-program IPL",
);

$helpers->unmock('kvm_device_ipl_methods');

# a QEMU binary answering device-list-properties: QEMU-mod types with the 'iplable' and
# 'ipl-method' properties, a type without them as in QEMU, and an unknown type
my $qmp_output = <<'EOF';
{"QMP": {"version": {}, "capabilities": []}}
{"return": {}}
{"return": [{"name": "devno", "type": "str"}, {"name": "iplable", "type": "bool", "default-value": true}, {"name": "ipl-method", "type": "string", "default-value": "ccw"}], "id": "fba-ccw"}
{"return": [{"name": "iplable", "type": "bool", "default-value": false}, {"name": "ipl-method", "type": "string", "default-value": "none"}], "id": "virtio-scsi-ccw"}
{"return": [{"name": "iplable", "type": "bool", "default-value": true}, {"name": "ipl-method", "type": "string", "default-value": "firmware"}], "id": "virtio-blk-ccw"}
{"return": [{"name": "drive", "type": "str"}], "id": "scsi-hd"}
{"return": [{"name": "drive", "type": "str"}], "id": "qeth-ccw"}
{"error": {"class": "GenericError", "desc": "Device 'x-unknown' not found"}, "id": "x-unknown"}
{"return": {}}
EOF

my $dir = tempdir(CLEANUP => 1);
my $binary = "$dir/kvm-ipl";
file_set_contents($binary, "#!/bin/sh\ncat >/dev/null\ncat <<'EOF'\n${qmp_output}EOF\n", 0755);
is_deeply(
    PVE::QemuServer::Helpers::kvm_device_ipl_methods(
        $binary,
        [qw(fba-ccw virtio-scsi-ccw virtio-blk-ccw scsi-hd qeth-ccw x-unknown)],
    ),
    {
        'fba-ccw' => 'ccw',
        'virtio-scsi-ccw' => 'none',
        'virtio-blk-ccw' => 'firmware',
        'scsi-hd' => 'firmware', # no properties, as in QEMU: default
        'qeth-ccw' => 'none',
        'x-unknown' => 'none',
    },
    'IPL methods from device-list-properties, defaults without the properties',
);

done_testing();
