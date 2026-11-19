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
        qr/^local:100\/vm-100-disk-1\.raw,devno=0\.0\.0201,size=1G$/,
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

done_testing();
