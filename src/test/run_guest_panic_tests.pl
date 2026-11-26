#!/usr/bin/perl

use v5.36;
no warnings 'portable'; # 64-bit hexadecimal literals

use lib qw(..);

# the shutdown tests below must not wait for real
my $slept = 0;
BEGIN { *CORE::GLOBAL::sleep = sub { $slept += $_[0] // 1; return $_[0] // 1; }; }

use Test::MockModule;
use Test::More;

use PVE::JSONSchema;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::DisabledWait;

# crash-information per QOM path, like QEMU reports it; CPUs without an entry did not crash
my $crash_information;
my $cpus;

my $qemu_server = Test::MockModule->new('PVE::QemuServer');
$qemu_server->mock(
    mon_cmd => sub {
        my ($vmid, $cmd, %params) = @_;

        return $cpus if $cmd eq 'query-cpus-fast';
        die "unexpected command '$cmd'\n" if $cmd ne 'qom-get';
        die "unexpected property '$params{property}'\n"
            if $params{property} ne 'crash-information';

        my $info = $crash_information->{ $params{path} };
        die "No crash occurred\n" if !$info;
        return $info;
    },
);

my sub cpu_list($count) {
    return [map { { 'cpu-index' => $_, 'qom-path' => "/machine/unattached/device[$_]" } }
        0 .. $count - 1];
}

my $tests = [
    {
        name => 's390x disabled wait on the second CPU',
        cpus => 2,
        crash_information => {
            '/machine/unattached/device[1]' => {
                type => 's390',
                core => 1,
                'psw-mask' => 562956395872256,
                'psw-addr' => 0,
                reason => 'disabled-wait',
            },
        },
        expected => {
            type => 's390',
            core => 1,
            'psw-mask' => '0002000180000000',
            'psw-addr' => '0000000000000000',
            reason => 'disabled-wait',
        },
    },
    {
        name => 's390x 64-bit address keeps all digits',
        cpus => 1,
        crash_information => {
            '/machine/unattached/device[0]' => {
                type => 's390',
                core => 0,
                'psw-mask' => 0x0706000180000000,
                'psw-addr' => 18446744073709551614,
                reason => 'pgmint-loop',
            },
        },
        expected => {
            type => 's390',
            core => 0,
            'psw-mask' => '0706000180000000',
            'psw-addr' => 'fffffffffffffffe',
            reason => 'pgmint-loop',
        },
    },
    {
        name => 'Hyper-V crash MSRs',
        cpus => 4,
        crash_information => {
            '/machine/unattached/device[2]' => {
                type => 'hyper-v',
                arg1 => 0x7e,
                arg2 => 0xffffffffc0000005,
                arg3 => 0xfffff8012345678a,
                arg4 => 0,
                arg5 => 1,
            },
        },
        expected => {
            type => 'hyper-v',
            arg1 => '000000000000007e',
            arg2 => 'ffffffffc0000005',
            arg3 => 'fffff8012345678a',
            arg4 => '0000000000000000',
            arg5 => '0000000000000001',
        },
    },
    {
        name => 'no CPU has crash information (pvepanic, older QEMU)',
        cpus => 2,
        crash_information => {},
        expected => undef,
    },
    {
        name => 'unknown crash information type',
        cpus => 1,
        crash_information => {
            '/machine/unattached/device[0]' => { type => 'future-arch', foo => 1 },
        },
        expected => undef,
    },
];

for my $test ($tests->@*) {
    $cpus = cpu_list($test->{cpus});
    $crash_information = $test->{crash_information};

    my $info = PVE::QemuServer::get_guest_panic_info(100);
    is_deeply($info, $test->{expected}, $test->{name});

    if ($info) {
        my $schema = $PVE::QemuServer::vmstatus_return_properties->{'panic-info'};
        eval { PVE::JSONSchema::validate($info, $schema) };
        is($@, '', "$test->{name}: matches the API schema");
    }
}

# the status fields: a disabled wait of an s390x CPU is told apart, other crashes are not
is_deeply(PVE::QemuServer::guest_panic_status_fields(undef), {}, 'no crash information');
my $wait = {
    type => 's390',
    core => 0,
    'psw-mask' => '0002000180000000',
    'psw-addr' => '0000000000000ccc',
    reason => 'disabled-wait',
};
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($wait),
    { 'panic-info' => $wait, 'disabled-wait' => '0000000000000ccc' },
    's390x disabled wait, no OS type: PSW address',
);
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($wait, 'other'),
    { 'panic-info' => $wait, 'disabled-wait' => '0000000000000ccc' },
    's390x disabled wait, OS type other: PSW address',
);
for my $ostype (qw(l26 l24)) {
    is_deeply(
        PVE::QemuServer::guest_panic_status_fields($wait, $ostype),
        { 'panic-info' => $wait },
        "s390x disabled wait, OS type $ostype: a kernel panic, no disabled wait",
    );
}
my $loop = { %$wait, reason => 'pgmint-loop' };
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($loop),
    { 'panic-info' => $loop },
    's390x program interrupt loop: no disabled wait',
);
my $hyperv = { type => 'hyper-v', map { ("arg$_" => '0000000000000001') } 1 .. 5 };
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($hyperv),
    { 'panic-info' => $hyperv },
    'Hyper-V crash: no disabled wait',
);
{
    my $fields = PVE::QemuServer::guest_panic_status_fields($wait);
    for my $key (sort keys $fields->%*) {
        my $schema = $PVE::QemuServer::vmstatus_return_properties->{$key};
        eval { PVE::JSONSchema::validate($fields->{$key}, $schema) };
        is($@, '', "status field '$key' matches the API schema");
    }
}

# the wait state code: the rightmost three hexadecimal digits of the PSW address
is(PVE::QemuServer::DisabledWait::wait_code('0000000000000ccc'), 'CCC', 'wait code CCC');
is(PVE::QemuServer::DisabledWait::wait_code('00000000000a0961'), '961', 'wait code 961');
is(PVE::QemuServer::DisabledWait::wait_code('0'), '000', 'wait code of a short address');

is_deeply(
    PVE::QemuServer::DisabledWait::parse_shutdown_wait(undef),
    { codes => undef, guest => 0 },
    'option not set: any code after a requested shutdown',
);
is_deeply(
    PVE::QemuServer::DisabledWait::parse_shutdown_wait('codes=ccc;961;0A,guest=1'),
    { codes => { CCC => 1, 961 => 1, '00A' => 1 }, guest => 1 },
    'codes and guest',
);
eval { PVE::QemuServer::DisabledWait::parse_shutdown_wait('codes=1000') };
like($@, qr/codes/, 'a wait code has at most three digits');
ok(PVE::QemuServer::option_exists('s390-shutdown-wait'), "'s390-shutdown-wait' is a VM option");

my $is_shutdown_wait = \&PVE::QemuServer::DisabledWait::is_shutdown_wait;
my $zconf = { arch => 's390x', ostype => 'other' };
ok($is_shutdown_wait->($zconf, '0000000000000ccc', 1), 'requested shutdown: any code by default');
ok($is_shutdown_wait->($zconf, '0000000000000123', 1), 'requested shutdown: also a crash code');
ok(!$is_shutdown_wait->($zconf, '0000000000000ccc', 0), 'no request, no guest option: no');
ok(
    !$is_shutdown_wait->({ %$zconf, ostype => 'l26' }, '0000000000000ccc', 1),
    'Linux guest: a kernel panic, never a shutdown',
);
ok(
    !$is_shutdown_wait->({ %$zconf, arch => 'x86_64' }, '0000000000000ccc', 1),
    'not s390x: no',
);
{
    my $conf = { %$zconf, 's390-shutdown-wait' => 'codes=ccc;961' };
    ok($is_shutdown_wait->($conf, '0000000000000ccc', 1), 'listed code, requested');
    ok($is_shutdown_wait->($conf, '0000000000000961', 1), 'other listed code, requested');
    ok(!$is_shutdown_wait->($conf, '0000000000000123', 1), 'code not listed, requested: no');
    ok(!$is_shutdown_wait->($conf, '0000000000000ccc', 0), 'listed code, no request: no');
}
{
    my $conf = { %$zconf, 's390-shutdown-wait' => 'codes=ccc,guest=1' };
    ok($is_shutdown_wait->($conf, '0000000000000ccc', 0), 'guest shut down with a listed code');
    ok(!$is_shutdown_wait->($conf, '0000000000000123', 0), 'guest wait with another code: no');
}

# a shutdown requested through the host: QEMU of a VM in a disabled wait is quit
{
    my $vm_conf;
    my $state; # 'running', 'guest-panicked', 'exited'
    my $psw_addr;
    my $panic_after; # query-status calls before the guest enters the disabled wait
    my @cmds;
    my $cleanup = 0;

    my $config = Test::MockModule->new('PVE::QemuConfig');
    $config->mock(
        load_config => sub { return {%$vm_conf} },
        check_lock => sub { },
    );
    my $guest_helpers = Test::MockModule->new('PVE::GuestHelpers');
    $guest_helpers->mock(exec_hookscript => sub { });

    $qemu_server->mock(
        check_running => sub { return $state ne 'exited' ? 4711 : undef },
        vm_stop_cleanup => sub { $cleanup++ },
        mon_cmd => sub {
            my ($vmid, $cmd, %params) = @_;
            push @cmds, $cmd;
            if ($cmd eq 'system_powerdown') {
                return;
            } elsif ($cmd eq 'query-status') {
                $state = 'guest-panicked' if $state eq 'running' && $panic_after-- <= 0;
                return { status => $state };
            } elsif ($cmd eq 'query-cpus-fast') {
                return cpu_list(2);
            } elsif ($cmd eq 'qom-get') {
                die "No crash occurred\n"
                    if $state ne 'guest-panicked' || $params{path} !~ m/\[1\]$/;
                return {
                    type => 's390',
                    core => 1,
                    'psw-mask' => 0x0002000180000000,
                    'psw-addr' => hex($psw_addr),
                    reason => 'disabled-wait',
                };
            } elsif ($cmd eq 'quit') {
                $state = 'exited';
                return;
            }
            die "unexpected command '$cmd'\n";
        },
    );

    my $run = sub {
        my ($name, $conf, %opts) = @_;
        $vm_conf = $conf;
        $state = 'running';
        $psw_addr = $opts{psw_addr} // 'ccc';
        $panic_after = $opts{panic_after} // 2;
        @cmds = ();
        $cleanup = 0;
        $slept = 0;

        my $output = '';
        open(my $fh, '>', \$output);
        my $old = select($fh);
        eval {
            PVE::QemuServer::_do_vm_stop(
                {}, 100, 0, 0, $opts{timeout} // 60, 1, $opts{force},
            );
        };
        my $err = $@;
        select($old);
        close($fh);
        return ($err, $output);
    };

    my ($err, $out) = $run->('default', $zconf);
    is($err, '', 'requested shutdown, disabled wait: no error');
    like(
        $out,
        qr/wait state code X'CCC' \(PSW 0002000180000000 0000000000000ccc, CPU 1\): shutdown complete/,
        'requested shutdown, disabled wait: logs the PSW and the wait code',
    );
    is((grep { $_ eq 'quit' } @cmds), 1, 'requested shutdown, disabled wait: QEMU is quit');
    is($cmds[0], 'system_powerdown', 'the shutdown is requested with system_powerdown');
    is($cleanup, 1, 'requested shutdown, disabled wait: cleaned up');
    ok($slept < 10, 'requested shutdown, disabled wait: no timeout');

    ($err, $out) = $run->(
        'code not listed',
        { %$zconf, 's390-shutdown-wait' => 'codes=961' },
        timeout => 5,
    );
    like($err, qr/got timeout/, 'code not listed: the shutdown times out as before');
    like($out, qr/not a shutdown wait code/, 'code not listed: logged once');
    is((grep { $_ eq 'quit' } @cmds), 0, 'code not listed: QEMU is not quit');

    ($err, $out) = $run->('Linux', { %$zconf, ostype => 'l26' }, timeout => 5);
    like($err, qr/got timeout/, 'Linux guest: a disabled wait does not end the shutdown');
    is((grep { $_ eq 'query-status' } @cmds), 0, 'Linux guest: no status polling');

    ($err, $out) = $run->('already waiting', $zconf, panic_after => 0);
    is($err, '', 'VM already in a disabled wait: the shutdown stops it');

    $qemu_server->unmock('check_running', 'vm_stop_cleanup');
}

done_testing();
