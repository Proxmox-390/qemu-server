#!/usr/bin/perl

# Tests API handlers of PVE::API2::Qemu up to the point where they would access the guest config,
# for checks that only depend on the parameters.

use strict;
use warnings;

use lib qw(..);

use Storable qw(dclone);
use Test::MockModule;
use Test::More;

use PVE::API2::Qemu;
use PVE::RPCEnvironment;

my $rpcenv = PVE::RPCEnvironment->init('cli');

my $storage_module = Test::MockModule->new('PVE::Storage');
$storage_module->mock(config => sub { return {}; });

my $replication_config_module = Test::MockModule->new('PVE::ReplicationConfig');
$replication_config_module->mock(
    new => sub { return bless {}, 'PVE::ReplicationConfig'; },
    check_for_existing_jobs => sub { return; },
);

my $qemu_config_module = Test::MockModule->new('PVE::QemuConfig');

# the checks of most tests come before the config gets loaded
sub mock_unreachable_config {
    $qemu_config_module->mock(
        load_config => sub { die "reached load_config\n"; },
        lock_config => sub { die "reached lock_config\n"; },
    );
    $qemu_config_module->unmock('write_config') if $qemu_config_module->is_mocked('write_config');
}
mock_unreachable_config();

# Returns the error of calling the API method $method with $param, either the parameter errors as
# hash or the error message.
sub api_error {
    my ($method, $param) = @_;

    eval { PVE::API2::Qemu->$method({ node => 'localhost', vmid => 100, $param->%* }); };
    my $err = $@;

    return ref($err) ? $err->{errors} : $err;
}

my $not_in_schema =
    'property is not defined in schema and the schema does not allow additional properties';

for my $user ('root@pam', 'user@pve') {
    $rpcenv->set_user($user);

    for my $method ('update_vm', 'update_vm_async') {
        is_deeply(
            api_error($method, { delete => 'meta' }),
            { delete => "option 'meta' is read-only" },
            "$method: $user cannot delete 'meta'",
        );
        is_deeply(
            api_error($method, { delete => 'name,meta' }),
            { delete => "option 'meta' is read-only" },
            "$method: $user cannot delete 'meta' together with other options",
        );
        is_deeply(
            api_error($method, { revert => 'meta' }),
            { revert => "option 'meta' is read-only" },
            "$method: $user cannot revert 'meta'",
        );
        is_deeply(
            api_error($method, { meta => 'ctime=1700000000' }),
            { meta => $not_in_schema },
            "$method: $user cannot set 'meta'",
        );
    }

    is_deeply(
        api_error('create_vm', { meta => 'ctime=1700000000' }),
        { meta => $not_in_schema },
        "create_vm: $user cannot set 'meta'",
    );
    is_deeply(
        api_error(
            'create_vm',
            { archive => 'local:backup/vzdump-qemu-100.vma.zst', meta => 'ctime=1700000000' },
        ),
        { meta => $not_in_schema },
        "create_vm: $user cannot override 'meta' of a restored backup",
    );
}

$rpcenv->set_user('root@pam');

is(
    api_error('update_vm', { delete => 'name' }),
    "reached load_config\n",
    'update_vm: deleting other options passes the parameter checks',
);
is(
    api_error('update_vm', { revert => 'name' }),
    "reached load_config\n",
    'update_vm: reverting other options passes the parameter checks',
);

subtest 'pending changes of meta are dropped' => sub {
    my $meta = 'creation-qemu=10.1.2,ctime=1762000000';
    my $stored;

    $qemu_config_module->mock(
        load_config => sub { return dclone($stored); },
        lock_config => sub {
            my ($class, $vmid, $code, @param) = @_;
            return $code->(@param);
        },
        write_config => sub {
            my ($class, $vmid, $conf) = @_;
            $stored = dclone($conf);
        },
    );
    my $qemu_server_module = Test::MockModule->new('PVE::QemuServer');
    $qemu_server_module->mock(check_running => sub { return 0; });

    for my $pending ({ meta => 'creation-qemu=8.0.2,ctime=1500000000' }, { delete => 'meta' }) {
        my $what = join(',', map { "$_: $pending->{$_}" } sort keys $pending->%*);
        $stored = { name => 'old', meta => $meta, pending => $pending, snapshots => {} };

        my $warnings = '';
        local $SIG{__WARN__} = sub { $warnings .= $_[0]; };
        PVE::API2::Qemu->update_vm({ node => 'localhost', vmid => 100, name => 'new' });

        is($stored->{name}, 'new', "other change applied ($what)");
        is($stored->{meta}, $meta, "meta unchanged ($what)");
        is_deeply($stored->{pending}, {}, "pending change of meta dropped ($what)");
        like(
            $warnings,
            qr/^ignoring pending change of read-only option 'meta'$/m,
            "dropped change is logged ($what)",
        );
    }

    mock_unreachable_config();
};

subtest 's390x: qeth adapters without a device number get one' => sub {
    my $stored;

    $qemu_config_module->mock(
        load_config => sub { return dclone($stored); },
        lock_config => sub {
            my ($class, $vmid, $code, @param) = @_;
            return $code->(@param);
        },
        write_config => sub {
            my ($class, $vmid, $conf) = @_;
            # what writing the config file checks: every value is defined
            for my $section ($conf, $conf->{pending} // {}) {
                for my $key (keys %$section) {
                    die "unable to parse value of '$key' - got undefined value\n"
                        if !defined($section->{$key});
                }
            }
            $stored = dclone($conf);
        },
    );
    my $qemu_server_module = Test::MockModule->new('PVE::QemuServer');
    $qemu_server_module->mock(check_running => sub { return 1; }); # changes stay pending
    $qemu_server_module->mock(vmconfig_hotplug_pending => sub { return; });

    $stored = {
        arch => 's390x',
        ostype => 'other',
        net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
        terminal0 => '0.0.0404',
        pending => {},
        snapshots => {},
    };

    PVE::API2::Qemu->update_vm({
        node => 'localhost',
        vmid => 100,
        net1 => 'qeth=BC:24:11:00:00:02,bridge=vmbr0',
    });
    is(
        $stored->{pending}->{net1},
        'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0408',
        'new qeth adapter gets the next free device number',
    );
    ok(!exists($stored->{net1}), 'no empty current value of the new qeth adapter');

    PVE::API2::Qemu->update_vm({
        node => 'localhost',
        vmid => 100,
        net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr1',
    });
    is(
        $stored->{pending}->{net0},
        'qeth=BC:24:11:00:00:01,bridge=vmbr1,devno=0.0.0400',
        'changed qeth adapter keeps its device number',
    );

    PVE::API2::Qemu->update_vm({
        node => 'localhost',
        vmid => 100,
        net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0480',
    });
    is(
        $stored->{pending}->{net0},
        'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0480',
        'device number change of a qeth adapter is a pending change',
    );

    eval {
        PVE::API2::Qemu->update_vm({
            node => 'localhost',
            vmid => 100,
            terminal0 => '0.0.0480',
        });
    };
    like($@, qr/device number 0\.0\.0480 is already used by net0/, 'devno conflict refused');

    mock_unreachable_config();
};

subtest 's390x: adding DASDs to an existing VM' => sub {
    my $stored;
    my $freed = [];
    my $allocated = 0;

    $qemu_config_module->mock(
        load_config => sub { return dclone($stored); },
        lock_config => sub {
            my ($class, $vmid, $code, @param) = @_;
            return $code->(@param);
        },
        write_config => sub {
            my ($class, $vmid, $conf) = @_;
            # what writing the config file checks: every value is defined
            for my $key (keys %$conf) {
                die "unable to parse value of '$key' - got undefined value\n"
                    if !defined($conf->{$key});
            }
            $stored = dclone($conf);
        },
    );
    my $qemu_server_module = Test::MockModule->new('PVE::QemuServer');
    $qemu_server_module->mock(check_running => sub { return 1; }); # changes stay pending
    $qemu_server_module->mock(vmconfig_hotplug_pending => sub { return; });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(
        config => sub { return {}; },
        storage_config => sub {
            return { type => 'dir', path => '/var/lib/vz', content => { images => 1 } };
        },
        storage_check_enabled => sub { return; },
        storage_default_format => sub { return ('raw', ['raw']); },
        vdisk_alloc => sub {
            my ($cfg, $storeid, $vmid, $fmt, $name, $size) = @_;
            $allocated++;
            return "$storeid:$vmid/vm-$vmid-disk-$allocated.raw";
        },
        vdisk_free => sub { push @$freed, $_[1]; },
    );
    my $rpcenv_module = Test::MockModule->new('PVE::RPCEnvironment');
    $rpcenv_module->mock(check => sub { return 1; });
    my $dasd = Test::MockModule->new('PVE::QemuServer::DASD');
    $dasd->mock(init_ckd_volume => sub { die "header write failed\n"; });

    $stored = {
        arch => 's390x',
        ostype => 'other',
        fba0 => 'local:100/vm-100-disk-0.raw,devno=0.0.0200,size=1G',
        pending => {},
        snapshots => {},
    };

    PVE::API2::Qemu->update_vm({ node => 'localhost', vmid => 100, fba7 => 'local:1' });
    like(
        $stored->{pending}->{fba7} // '',
        qr/^local:100\/vm-100-disk-1\.raw,devno=0\.0\.0201,model=9336,size=1G$/,
        'new FBA DASD created with the next free device number',
    );
    ok(!exists($stored->{fba7}), 'no empty current value left in the config');
    is_deeply($freed, [], 'nothing freed');

    eval {
        PVE::API2::Qemu->update_vm(
            { node => 'localhost', vmid => 100, ckd3 => 'local:0,model=3390-1' });
    };
    like($@, qr/header write failed/, 'failing CKD creation');
    is_deeply($freed, ['local:100/vm-100-disk-2.raw'], 'the new volume is freed on failure');
    ok(!exists($stored->{pending}->{ckd3}) && !exists($stored->{ckd3}), 'no ckd3 in the config');

    mock_unreachable_config();
};

subtest 's390x: options s390x VMs cannot have are refused when set' => sub {
    my $stored;
    my $written = 0;

    $qemu_config_module->mock(
        load_config => sub { return dclone($stored); },
        lock_config => sub {
            my ($class, $vmid, $code, @param) = @_;
            return $code->(@param);
        },
        write_config => sub { $written++; },
    );

    $stored = { arch => 's390x', ostype => 'l26', pending => {}, snapshots => {} };

    for my $test (
        [{ ide2 => 'none,media=cdrom' }, qr/^ide2: IDE is not supported on s390x/],
        [{ ide0 => 'local:cloudinit' }, qr/^ide0: IDE is not supported on s390x/],
        [{ sata1 => 'none,media=cdrom' }, qr/^sata1: SATA is not supported on s390x/],
        [{ 'amd-sev' => 'type=std' }, qr/^amd-sev: AMD SEV is not supported on s390x/],
        [{ 'intel-tdx' => 'type=tdx' }, qr/^intel-tdx: Intel TDX is not supported on s390x/],
        [
            { name => 'other', ide2 => 'none,media=cdrom' },
            qr/^ide2: IDE is not supported on s390x/,
        ],
    ) {
        my ($param, $expected) = @$test;
        my $what = join(' ', map { "--$_ $param->{$_}" } sort keys %$param);
        eval { PVE::API2::Qemu->update_vm({ node => 'localhost', vmid => 100, %$param }) };
        like($@, $expected, "update_vm $what refused");
    }
    is($written, 0, 'nothing written, also not the other options');

    my $cluster_module = Test::MockModule->new('PVE::Cluster');
    $cluster_module->mock(
        check_vmid_unused => sub { return; },
        check_cfs_quorum => sub { return; },
    );
    my $rpcenv_module = Test::MockModule->new('PVE::RPCEnvironment');
    $rpcenv_module->mock(check => sub { return 1; });
    for my $test (
        [{ ide2 => 'none,media=cdrom' }, qr/^ide2: IDE is not supported on s390x/],
        [{ 'amd-sev' => 'type=std' }, qr/^amd-sev: AMD SEV is not supported on s390x/],
    ) {
        my ($param, $expected) = @$test;
        my $what = join(' ', map { "--$_ $param->{$_}" } sort keys %$param);
        eval {
            PVE::API2::Qemu->create_vm(
                { node => 'localhost', vmid => 100, arch => 's390x', %$param });
        };
        like($@, $expected, "create_vm $what refused");
    }

    mock_unreachable_config();
};

subtest 's390x: importing a DASD from a storage volume' => sub {
    my $stored = {
        arch => 's390x',
        ostype => 'other',
        pending => {},
        snapshots => {},
    };

    $qemu_config_module->mock(
        load_config => sub { return dclone($stored); },
        lock_config => sub {
            my ($class, $vmid, $code, @param) = @_;
            return $code->(@param);
        },
        write_config => sub { },
    );
    my $qemu_server_module = Test::MockModule->new('PVE::QemuServer');
    $qemu_server_module->mock(check_running => sub { return 1; });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(
        config => sub { return {}; },
        storage_config => sub {
            return {
                type => 'dir',
                path => '/var/lib/vz',
                content => { images => 1, import => 1 },
            };
        },
        storage_check_enabled => sub { return; },
        check_volume_access => sub { return; },
        parse_volname => sub {
            my ($cfg, $volid) = @_;
            return ('import', 'x.ckd', undef, undef, undef, undef, 'raw')
                if $volid eq 'local:import/x.ckd';
            die "unexpected volume '$volid'\n";
        },
        # both return more in list context, like the real ones
        path => sub {
            my $path = '/var/lib/vz/import/x.ckd';
            return wantarray ? ($path, undef, 'import') : $path;
        },
        volume_size_info => sub {
            return wantarray ? (2846431744, 'raw', 2846431744, undef) : 2846431744;
        },
    );
    my $rpcenv_module = Test::MockModule->new('PVE::RPCEnvironment');
    $rpcenv_module->mock(check => sub { return 1; });
    my $dasd = Test::MockModule->new('PVE::QemuServer::DASD');
    my $args;
    $dasd->mock(
        check_ckd_import_source => sub {
            $args = [@_];
            die "checked\n";
        },
    );

    eval {
        PVE::API2::Qemu->update_vm({
            node => 'localhost',
            vmid => 100,
            ckd0 => 'local:0,import-from=local:import/x.ckd',
        });
    };
    like($@, qr/checked/, 'reached the check of the source image');
    is_deeply(
        $args,
        ['/var/lib/vz/import/x.ckd', 'raw', 2846431744],
        'path, format and size of the source image',
    );

    mock_unreachable_config();
};

subtest 's390x: overlapping CCW device numbers are refused on every change' => sub {
    my $stored;
    my $written = 0;

    $qemu_config_module->mock(
        load_config => sub { return dclone($stored); },
        lock_config => sub {
            my ($class, $vmid, $code, @param) = @_;
            return $code->(@param);
        },
        write_config => sub {
            my ($class, $vmid, $conf) = @_;
            $written++;
            $stored = dclone($conf);
        },
    );
    my $qemu_server_module = Test::MockModule->new('PVE::QemuServer');
    $qemu_server_module->mock(check_running => sub { return 1; }); # changes stay pending
    $qemu_server_module->mock(vmconfig_hotplug_pending => sub { return; });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(
        config => sub { return {}; },
        check_volume_access => sub { return; },
        storage_config => sub {
            return { type => 'dir', path => '/var/lib/vz', content => { images => 1 } };
        },
        parse_volname => sub {
            my ($cfg, $volid) = @_;
            my ($name) = $volid =~ m!/([^/]+)$!;
            return ('images', $name, 100, undef, undef, undef, 'raw');
        },
    );
    $rpcenv->set_user('root@pam');

    my $base = {
        arch => 's390x',
        ostype => 'other',
        ckd0 => 'local:100/vm-100-SYSRS1.raw,devno=0.0.0300,size=8G',
        fba1 => 'local:100/vm-100-cloudinit.qcow2,media=cdrom,devno=0.0.0200',
        net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
        terminal0 => '0.0.0700',
        tape0 => 'none',
        pending => {},
        snapshots => {},
    };

    for my $test (
        [
            { ckd1 => 'local:100/vm-100-X.raw,devno=0300' },
            ckd1 => qr/^ckd1: device number 0\.0\.0300 is already used by ckd0/,
        ],
        [
            { terminal1 => '0.0.0402' },
            terminal1 => qr/^terminal1: device number 0\.0\.0402 is already used by net0 \(terminal1: 0\.0\.0402, net0: 0\.0\.0400-0\.0\.0402\)/,
        ],
        [
            { net1 => 'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0700' },
            net1 => qr/^net1: device number 0\.0\.0700 is already used by terminal0/,
        ],
        [
            { tape1 => 'none,devno=0.0.0200' },
            tape1 => qr/^tape1: device number 0\.0\.0200 is already used by fba1/,
        ],
        [
            { tape1 => 'none' }, # default 0.0.0581
            undef,
        ],
        [
            { fba2 => 'local:100/vm-100-Y.raw,devno=0.0.0042' },
            fba2 => qr/^fba2: device number 0\.0\.0042 is reserved for the virtio devices/,
        ],
        [
            { terminal0 => '0.0.0300' },
            terminal0 => qr/^terminal0: device number 0\.0\.0300 is already used by ckd0/,
        ],
        [
            { ckd0 => 'local:100/vm-100-SYSRS1.raw,devno=0.0.0700', terminal0 => '0.0.0300' },
            undef, # swapped in one change
        ],
        [
            { net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.06fe' },
            net0 => qr/^net0: device number 0\.0\.06fe must be a multiple of 4/,
        ],
    ) {
        my ($param, $key, $expected) = @$test;
        $stored = dclone($base);
        $written = 0;
        my $what = join(' ', map { "--$_ $param->{$_}" } sort keys %$param);
        for my $method (qw(update_vm update_vm_async)) {
            my $err = api_error($method, $param);
            if ($expected) {
                is_deeply([keys %$err], [$key], "$method $what: error on $key")
                    if ref($err) eq 'HASH';
                like(ref($err) ? $err->{$key} : $err, $expected, "$method $what refused");
                is($written, 0, "$method $what: nothing written");
            } elsif ($method eq 'update_vm') {
                ok(!ref($err) || !grep { m/devno|terminal|ckd|net|tape/ } keys %$err,
                    "$method $what: no device number error") or diag explain $err;
            }
        }
    }

    # a config that has an overlap already (made by hand, or before overlaps were refused)
    $stored = dclone($base);
    $stored->{terminal1} = '0.0.0300';
    my $err = api_error('update_vm', { name => 'other' });
    is_deeply([keys %$err], ['terminal1'], 'unrelated change: error on the overlapping device');
    like(
        $err->{terminal1},
        qr/^the configuration has conflicting device numbers, change the device number of 'terminal1' or 'ckd0' \(or remove it\) first - terminal1: device number 0\.0\.0300 is already used by ckd0/,
        'unrelated change of an overlapping config: clear error',
    );
    is($written, 0, 'unrelated change of an overlapping config: nothing written');
    $err = api_error('update_vm', { terminal1 => '0.0.0701' });
    ok(!ref($err) || !$err->{terminal1}, 'the overlap can be fixed') or diag explain $err;
    $stored = dclone($base);
    $stored->{terminal1} = '0.0.0300';
    $err = api_error('update_vm', { delete => 'terminal1' });
    ok(!ref($err) || !$err->{terminal1}, 'the overlapping device can be removed')
        or diag explain $err;

    # pending changes are checked when they are applied
    $stored = dclone($base);
    $stored->{pending} = { terminal1 => '0.0.0300' };
    eval { PVE::QemuServer::vmconfig_apply_pending(100, dclone($stored), {}) };
    like(
        $@,
        qr/^terminal1: device number 0\.0\.0300 is already used by ckd0/,
        'pending change with an overlap is not applied',
    );
    my $errors = {};
    $qemu_server_module->unmock('vmconfig_hotplug_pending');
    my $hotplug_conf = dclone($stored);
    my $machine_module = Test::MockModule->new('PVE::QemuServer::Machine');
    $machine_module->mock(get_current_qemu_machine => sub { return 'czam-v1'; });
    eval {
        PVE::QemuServer::vmconfig_hotplug_pending(100, $hotplug_conf, {}, undef, $errors);
    };
    like(
        $errors->{terminal1} // $@,
        qr/terminal1: device number 0\.0\.0300 is already used by ckd0/,
        'pending change with an overlap is not hot-plugged',
    );

    # creation
    my $cluster_module = Test::MockModule->new('PVE::Cluster');
    $cluster_module->mock(
        check_vmid_unused => sub { return; },
        check_cfs_quorum => sub { return; },
    );
    my $rpcenv_module = Test::MockModule->new('PVE::RPCEnvironment');
    $rpcenv_module->mock(check => sub { return 1; });
    $err = api_error(
        'create_vm',
        {
            arch => 's390x',
            net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
            terminal0 => '0.0.0401',
        },
    );
    is_deeply([keys %$err], ['terminal0'], 'create: error on the terminal');
    like($err->{terminal0}, qr/already used by net0/, 'create: overlap refused');

    mock_unreachable_config();
};

subtest 's390x: CKD DASDs are not resized' => sub {
    is_deeply(
        [keys %{ api_error('resize_vm', { disk => 'ckd0', size => '+1G' }) }],
        ['disk'],
        'resize of a CKD DASD: parameter error',
    );
    like(
        api_error('resize_vm', { disk => 'ckd3', size => '20G' })->{disk},
        qr/^CKD DASDs cannot be resized/,
        'resize of a CKD DASD refused',
    );
    $rpcenv->set_user('root@pam');
    my $err = api_error('resize_vm', { disk => 'fba0', size => '+1G' });
    is(ref($err), '', 'resize of an FBA DASD is not refused by the parameter check');
    like($err, qr/reached lock_config|tasks|worker/i, 'resize of an FBA DASD goes ahead')
        or diag explain $err;
};

subtest 's390x hosts run s390x VMs only' => sub {
    my $qemu_server_module = Test::MockModule->new('PVE::QemuServer');
    $qemu_server_module->mock(get_host_arch => sub { return 's390x'; });
    my $cluster_module = Test::MockModule->new('PVE::Cluster');
    $cluster_module->mock(
        check_vmid_unused => sub { return; },
        check_cfs_quorum => sub { return; },
    );
    my $rpcenv_module = Test::MockModule->new('PVE::RPCEnvironment');
    $rpcenv_module->mock(check => sub { return 1; });

    for my $method (qw(update_vm update_vm_async create_vm)) {
        for my $arch (qw(x86_64 aarch64)) {
            my $err = api_error($method, { arch => $arch });
            is(ref($err), 'HASH', "$method arch=$arch: parameter error");
            like(
                ref($err) ? $err->{arch} : $err,
                qr/architecture '$arch' is not supported, an s390x host runs s390x VMs only/,
                "$method arch=$arch refused",
            );
        }
    }
    eval { PVE::QemuServer::check_vm_arch_supported('s390x') };
    is($@, '', 'arch=s390x accepted');
    eval { PVE::QemuServer::check_restore_config({ arch => 'x86_64' }) };
    like($@, qr/architecture 'x86_64' is not supported/, 'restore of a foreign VM refused');
    eval {
        PVE::QemuServer::check_restore_config({
            arch => 's390x',
            ckd0 => 'local:1/x.raw,devno=0.0.0300',
            ckd1 => 'local:1/y.raw,devno=0.0.0300',
        });
    };
    like($@, qr/^ckd1: device number 0\.0\.0300 is already used by ckd0/, 'restore with overlap');

    $qemu_server_module->mock(get_host_arch => sub { return 'x86_64'; });
    eval { PVE::QemuServer::check_vm_arch_supported('aarch64') };
    is($@, '', 'other hosts are not affected');
};

# The s390x API methods that read root-only files, run QEMU or connect to its sockets run in
# pvedaemon (sclp-log ran as www-data in pveproxy and could not read the log)
subtest 's390x methods run privileged' => sub {
    for my $name (qw(sclp_log sclp_command ipl_devices export_ova)) {
        my $info = PVE::API2::Qemu->map_method_by_name($name);
        ok($info && $info->{protected}, "$name is protected");
    }
};

done_testing();
