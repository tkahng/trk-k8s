// Phase 8 — the same three machines, running Talos Linux instead of
// Ubuntu+kubeadm. A COPY of infra/azure rather than a flag on it, because
// the differences are structural, not cosmetic (see below), and the point
// of the phase is to measure exactly how structural.
//
// PLAN.md predicted "infra/<provider>/ survives unchanged" for the Talos
// lab. That prediction is WRONG, and here is the evidence — four changes,
// none of them optional:
//
//  1. IMAGE: a managed image built from a factory VHD (infra/azure-talos/
//     image.sh), not Canonical's marketplace offer. Talos publishes no
//     Azure marketplace or community-gallery image at all.
//  2. NO SSH — but Azure demands the paperwork anyway. Talos has no shell
//     and no SSH daemon; the API on :50000 is the only way in. Yet Azure
//     REFUSES to create a VM from a generalized managed image without an
//     osProfile: "Required parameter 'osProfile' is missing (null)" (hit
//     2026-08-28). So the machine is handed an admin username and a public
//     key that nothing on it will ever read. The inventory contract's
//     sshUser field is likewise carried and meaningless.
//  3. NSG: port 50000/tcp for the Talos API, alongside 6443. Without it
//     `talosctl` cannot reach a node and the cluster cannot be configured
//     at all.
//  4. NO customData: the nodes boot UNCONFIGURED into maintenance mode on
//     purpose. Talos accepts machine config via customData on first boot,
//     but that config must embed the cluster endpoint and CA material —
//     which do not exist until the public IPs do. Rather than fight that
//     circularity inside one `pulumi up`, the machines come up empty and
//     cluster-talos/bootstrap.sh applies config over the network. Same
//     shape as the kubeadm flow: provision, then configure.
package main

import (
	"fmt"

	"github.com/pulumi/pulumi-azure-native-sdk/compute/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/network/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v3"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

type node struct {
	name      string
	role      string
	privateIP string
	size      string
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "trk-k8s-azure-talos")
		location := config.New(ctx, "azure-native").Require("location")
		myIP := cfg.Require("myIp")
		// Built once by image.sh into the locked persistent group.
		talosImageID := cfg.Require("talosImageId")
		// Required by Azure, ignored by Talos. See the osProfile note below.
		sshPublicKey := cfg.Require("sshPublicKey")

		tags := pulumi.StringMap{
			"cluster":   pulumi.String("trk-k8s-talos"),
			"lifecycle": pulumi.String("ephemeral"),
			"phase":     pulumi.String("8"),
		}

		// Its own resource group, so the Talos lab can be destroyed without
		// touching anything the kubeadm cluster owns — and so both can be
		// inspected side by side in the portal while the comparison is
		// being written up.
		rg, err := resources.NewResourceGroup(ctx, "rg-trk-k8s-talos", &resources.ResourceGroupArgs{
			ResourceGroupName: pulumi.String("rg-trk-k8s-talos"),
			Location:          pulumi.String(location),
			Tags:              tags,
		})
		if err != nil {
			return err
		}

		nodeIdentityID := cfg.Require("nodeIdentityId")

		nsg, err := network.NewNetworkSecurityGroup(ctx, "nsg-trk-k8s-talos", &network.NetworkSecurityGroupArgs{
			NetworkSecurityGroupName: pulumi.String("nsg-trk-k8s-talos"),
			ResourceGroupName:        rg.Name,
			Location:                 rg.Location,
			Tags:                     tags,
			SecurityRules: network.SecurityRuleTypeArray{
				// 50000 replaces 22: this is the whole "no SSH" difference,
				// expressed as one firewall rule.
				tcpRule("AllowTalosApiFromAdmin", 100, "50000", myIP),
				tcpRule("AllowApiServerFromAdmin", 110, "6443", myIP),
				tcpRule("AllowGatewayHttpFromAdmin", 120, "30080", myIP),
				tcpRule("AllowGatewayHttpsFromAdmin", 130, "30443", myIP),
			},
		})
		if err != nil {
			return err
		}

		vnet, err := network.NewVirtualNetwork(ctx, "vnet-trk-k8s-talos", &network.VirtualNetworkArgs{
			VirtualNetworkName: pulumi.String("vnet-trk-k8s-talos"),
			ResourceGroupName:  rg.Name,
			Location:           rg.Location,
			Tags:               tags,
			AddressSpace: &network.AddressSpaceArgs{
				AddressPrefixes: pulumi.StringArray{pulumi.String("10.0.0.0/16")},
			},
		})
		if err != nil {
			return err
		}

		subnet, err := network.NewSubnet(ctx, "snet-nodes", &network.SubnetArgs{
			SubnetName:         pulumi.String("snet-nodes"),
			ResourceGroupName:  rg.Name,
			VirtualNetworkName: vnet.Name,
			AddressPrefix:      pulumi.String("10.0.1.0/24"),
			NetworkSecurityGroup: &network.NetworkSecurityGroupTypeArgs{
				Id: nsg.ID(),
			},
		})
		if err != nil {
			return err
		}

		// Same address plan as every other provider and both OSes. The
		// contract's whole value is that this table never changes.
		nodes := []node{
			{name: "talos-cp-1", role: "control-plane", privateIP: "10.0.1.10", size: "Standard_D2als_v7"},
			{name: "talos-worker-1", role: "worker", privateIP: "10.0.1.11", size: "Standard_D4als_v7"},
			{name: "talos-worker-2", role: "worker", privateIP: "10.0.1.12", size: "Standard_D4als_v7"},
		}

		inventory := pulumi.Array{}
		for _, n := range nodes {
			n := n

			pip, err := network.NewPublicIPAddress(ctx, "pip-"+n.name, &network.PublicIPAddressArgs{
				PublicIpAddressName:      pulumi.String("pip-" + n.name),
				ResourceGroupName:        rg.Name,
				Location:                 rg.Location,
				Tags:                     tags,
				PublicIPAllocationMethod: pulumi.String(network.IPAllocationMethodStatic),
				Sku: &network.PublicIPAddressSkuArgs{
					Name: pulumi.String(network.PublicIPAddressSkuNameStandard),
				},
			})
			if err != nil {
				return err
			}

			nic, err := network.NewNetworkInterface(ctx, "nic-"+n.name, &network.NetworkInterfaceArgs{
				NetworkInterfaceName: pulumi.String("nic-" + n.name),
				ResourceGroupName:    rg.Name,
				Location:             rg.Location,
				Tags:                 tags,
				IpConfigurations: network.NetworkInterfaceIPConfigurationArray{
					&network.NetworkInterfaceIPConfigurationArgs{
						Name:                      pulumi.String("ipconfig1"),
						Subnet:                    &network.SubnetTypeArgs{Id: subnet.ID()},
						PrivateIPAddress:          pulumi.String(n.privateIP),
						PrivateIPAllocationMethod: pulumi.String(network.IPAllocationMethodStatic),
						PublicIPAddress:           &network.PublicIPAddressTypeArgs{Id: pip.ID()},
					},
				},
			})
			if err != nil {
				return err
			}

			_, err = compute.NewVirtualMachine(ctx, n.name, &compute.VirtualMachineArgs{
				VmName:            pulumi.String(n.name),
				ResourceGroupName: rg.Name,
				Location:          rg.Location,
				Tags:              tags,
				Identity: &compute.VirtualMachineIdentityArgs{
					Type: compute.ResourceIdentityTypeUserAssigned,
					UserAssignedIdentities: pulumi.StringArray{
						pulumi.String(nodeIdentityID),
					},
				},
				HardwareProfile: &compute.HardwareProfileArgs{
					VmSize: pulumi.String(n.size),
				},
				NetworkProfile: &compute.NetworkProfileArgs{
					NetworkInterfaces: compute.NetworkInterfaceReferenceArray{
						&compute.NetworkInterfaceReferenceArgs{
							Id:      nic.ID(),
							Primary: pulumi.Bool(true),
						},
					},
				},
				// Ceremonial. Talos has no /etc/passwd, no sshd, and no
				// cloud-init to consume any of this — but Azure's control
				// plane validates the REQUEST, not the image, and rejects a
				// generalized-image VM with no osProfile. The key below is
				// written to an authorized_keys file that will never exist.
				// customData is deliberately omitted: that is where a machine
				// config would go on first boot, and we want maintenance mode
				// instead (see note 4 above).
				OsProfile: &compute.OSProfileArgs{
					ComputerName:  pulumi.String(n.name),
					AdminUsername: pulumi.String("talos"),
					LinuxConfiguration: &compute.LinuxConfigurationArgs{
						DisablePasswordAuthentication: pulumi.Bool(true),
						Ssh: &compute.SshConfigurationArgs{
							PublicKeys: compute.SshPublicKeyTypeArray{
								&compute.SshPublicKeyTypeArgs{
									Path:    pulumi.String("/home/talos/.ssh/authorized_keys"),
									KeyData: pulumi.String(sshPublicKey),
								},
							},
						},
					},
				},
				StorageProfile: &compute.StorageProfileArgs{
					OsDisk: &compute.OSDiskArgs{
						CreateOption: pulumi.String(compute.DiskCreateOptionTypesFromImage),
						DiskSizeGB:   pulumi.Int(64),
						ManagedDisk: &compute.ManagedDiskParametersArgs{
							StorageAccountType: pulumi.String(compute.DiskStorageAccountTypes_Premium_LRS),
						},
						DeleteOption: pulumi.String(compute.DiskDeleteOptionTypesDelete),
					},
					ImageReference: &compute.ImageReferenceArgs{
						Id: pulumi.String(talosImageID),
					},
				},
			})
			if err != nil {
				return err
			}

			inventory = append(inventory, pulumi.Map{
				"name":      pulumi.String(n.name),
				"role":      pulumi.String(n.role),
				"privateIp": pulumi.String(n.privateIP),
				"publicIp":  pip.IpAddress.Elem(),
				// Carried for contract compatibility and IGNORED by every
				// Talos consumer. Kept rather than dropped so the contract
				// stays one shape across providers AND operating systems —
				// the alternative is a second contract, which is how seams
				// die. Recorded as an honest wart, not a design win.
				"sshUser": pulumi.String("n/a-talos"),
			})
			ctx.Export(fmt.Sprintf("%s-public-ip", n.name), pip.IpAddress.Elem())
		}

		ctx.Export("nodes", inventory)
		ctx.Export("resource-group", rg.Name)
		ctx.Export("talos-image", pulumi.String(talosImageID))
		// Where cluster-talos/bootstrap.sh points talosctl.
		ctx.Export("talos-endpoint", pulumi.Sprintf("https://%s:6443", "10.0.1.10"))
		return nil
	})
}

// One NSG rule allowing a single TCP port inbound from the admin CIDR.
func tcpRule(name string, priority int, port, srcCIDR string) network.SecurityRuleTypeInput {
	return &network.SecurityRuleTypeArgs{
		Name:                     pulumi.String(name),
		Priority:                 pulumi.Int(priority),
		Direction:                pulumi.String(network.SecurityRuleDirectionInbound),
		Access:                   pulumi.String(network.SecurityRuleAccessAllow),
		Protocol:                 pulumi.String(network.SecurityRuleProtocolTcp),
		SourceAddressPrefix:      pulumi.String(srcCIDR),
		SourcePortRange:          pulumi.String("*"),
		DestinationAddressPrefix: pulumi.String("*"),
		DestinationPortRange:     pulumi.String(port),
	}
}
