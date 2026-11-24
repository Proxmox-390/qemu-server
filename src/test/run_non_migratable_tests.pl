#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::MockModule;
use Test::More;

use PVE::QemuMigrate::Helpers;
use PVE::QemuServer::Helpers;

my $tests = [
    {
        name => 'no blockers',
        conf => { net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0' },
        state => 1,
        expected => [],
    },
    {
        name => 'mainframe devices can be migrated with state',
        conf => {
            net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0',
            net1 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
            net2 => 'bridge=vmbr0,model=qeth,devno=0.0.0404',
            ckd0 => 'local:100/vm-100-disk-0.raw,size=1G',
            tape0 => 'local:iso/install.aws',
            terminal0 => 'devno=0.0.0700',
        },
        state => 1,
        expected => [],
    },
    {
        name => 'confidential computing blocks state',
        conf => { 'amd-sev' => 'type=std' },
        state => 1,
        expected => ['amd-sev'],
    },
    {
        name => 'shared folder with SCLP file access blocks state, like virtiofs',
        conf => { sclpfile => 'share0', virtiofs0 => 'share1' },
        state => 1,
        expected => ['virtiofs', 'sclpfile'],
    },
    {
        name => 'shared folder with SCLP file access does not block offline migration',
        conf => { sclpfile => 'share0,readonly=0' },
        state => 0,
        expected => [],
    },
    {
        name => 'confidential computing does not block offline migration',
        conf => { 'amd-sev' => 'type=std' },
        state => 0,
        expected => [],
    },
];

for my $test ($tests->@*) {
    my @blockers = PVE::QemuMigrate::Helpers::check_non_migratable_resources(
        $test->{conf}, $test->{state}, 1,
    );
    is_deeply(\@blockers, $test->{expected}, $test->{name});
}

eval {
    PVE::QemuMigrate::Helpers::check_non_migratable_resources(
        { 'amd-sev' => 'type=std', ckd0 => 'local:100/vm-100-disk-0.raw,size=1G' },
        1,
        0,
    );
};
is(
    $@,
    "Cannot live-migrate, snapshot (with RAM), or hibernate a VM with: amd-sev\n",
    'blockers refuse live migration, RAM snapshots and hibernation up front',
);

# The shared folder with SCLP file access is a mapped directory of the node, like virtiofs: an
# offline migration needs the mapping on the target node.
{
    my $cluster = Test::MockModule->new('PVE::Cluster');
    $cluster->mock(get_nodelist => sub { return ['node1', 'node2']; });
    my $empty = { ids => {} };
    my $pci_mapping = Test::MockModule->new('PVE::Mapping::PCI');
    $pci_mapping->mock(config => sub { return $empty; });
    my $usb_mapping = Test::MockModule->new('PVE::Mapping::USB');
    $usb_mapping->mock(config => sub { return $empty; });
    my $dir_mapping = Test::MockModule->new('PVE::Mapping::Dir');
    my $media = { type => 'dir', map => ['node=node1,path=/mnt/media'] };
    $dir_mapping->mock(config => sub { return { ids => { media => $media } }; });

    my $conf = { sclpfile => 'media', net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0' };
    for my $state (0, 1) {
        my ($local, $mapped, $missing) =
            PVE::QemuMigrate::Helpers::check_local_resources($conf, $state, 1);
        my $what = $state ? 'running' : 'stopped';
        is_deeply($local, ['sclpfile'], "$what VM: the shared folder is a local resource");
        is_deeply($mapped, { sclpfile => { name => 'media' } }, "$what VM: a mapped one");
        is_deeply(
            $missing,
            { node1 => [], node2 => ['sclpfile'] },
            "$what VM: nodes without the directory mapping",
        );
    }
}

# /proc/sysinfo of s390x nodes: does the node run as a KVM guest (nested KVM)?
my $lpar = <<'EOF';
Manufacturer:         IBM
Type:                 3907
Sequence Code:        0000000000012345
LPAR Number:          1
LPAR Characteristics: Dedicated
LPAR Name:            LPAR01
LPAR CPUs Total:      6
EOF
my $kvm = $lpar . <<'EOF';
VM00 Name:            pve1
VM00 Control Program: KVM/Linux       
VM00 Adjustment:      1000
VM00 CPUs Total:      4
VM00 Extended Name:   pve1
EOF
my $zvm = $lpar . <<'EOF';
VM00 Name:            LINUX01
VM00 Control Program: z/VM    7.4.0   
VM00 Adjustment:      125
EOF
my $kvm_in_zvm = $kvm . <<'EOF';
VM01 Name:            LINUX01
VM01 Control Program: z/VM    7.4.0   
EOF
my $zvm_in_kvm = $zvm . <<'EOF';
VM01 Name:            pve1
VM01 Control Program: KVM/Linux       
EOF
for my $test (
    ['logical partition', $lpar, 0],
    ['KVM guest', $kvm, 1],
    ['z/VM guest', $zvm, 0],
    ['KVM guest under z/VM', $kvm_in_zvm, 1],
    ['z/VM under KVM: the closest level counts', $zvm_in_kvm, 0],
    ['no sysinfo', undef, 0],
    ['empty sysinfo', '', 0],
) {
    my ($name, $text, $expected) = $test->@*;
    is(PVE::QemuServer::Helpers::sysinfo_is_kvm_guest($text), $expected, "sysinfo: $name");
}

{
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    my $nested = 1;
    $helpers->mock(node_is_kvm_guest => sub { return $nested });
    my $rest_env = Test::MockModule->new('PVE::RESTEnvironment');
    my @warnings;
    $rest_env->mock(log_warn => sub { push @warnings, $_[0] });

    my $warns = sub {
        my ($conf) = @_;
        @warnings = ();
        PVE::QemuServer::Helpers::warn_ram_save_on_nested_kvm($conf);
        return scalar(@warnings);
    };
    is($warns->({ arch => 's390x', ostype => 'other' }), 1, 'nested KVM: mainframe guest warned');
    like(
        $warnings[0],
        qr/^this node runs as a KVM guest; saving the RAM of non-Linux mainframe guests can hang them on nested KVM$/,
        'nested KVM: warning',
    );
    is($warns->({ arch => 's390x' }), 1, 'nested KVM: no OS type is not Linux');
    is($warns->({ arch => 's390x', ostype => 'l26' }), 0, 'nested KVM: Linux guest not warned');
    is($warns->({ arch => 'x86_64', ostype => 'other' }), 0, 'nested KVM: other architectures');
    $nested = 0;
    is($warns->({ arch => 's390x', ostype => 'other' }), 0, 'logical partition: not warned');
}

done_testing();
