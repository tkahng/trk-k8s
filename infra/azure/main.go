// Machine provisioning on Azure for the kubeadm learning cluster.
//
// Third provider implementation of the same contract (ADR 002/009): export a
// `nodes` list of {name, role, publicIp, privateIp, sshUser} and the
// cluster/ layer cannot tell which cloud it got. Hetzner was written but
// never deployed; AWS ran for three weeks; this is the first time the seam
// is actually tested against a genuinely different cloud.
//
// The structural differences that matter, versus infra/aws:
//   - Everything lives in a RESOURCE GROUP. No AWS equivalent; it also
//     makes ADR 008's lifecycle boundary a first-class object (this group
//     is disposable; rg-trk-k8s-persistent is locked CanNotDelete).
//   - A VM is THREE resources: PublicIPAddress + NetworkInterface +
//     VirtualMachine. AWS bundles all of it into NewInstance.
//   - NSG rules carry explicit numeric PRIORITIES, and there is no
//     self-referencing rule — Azure's default rules already permit all
//     intra-VNet traffic, so the AWS "self rule" has no counterpart here.
//     Exactly the per-cloud firewall difference ADR 002 predicted, third
//     variation: Hetzner filtered only the public NIC, AWS denied
//     everything including internal, Azure allows internal by default.
//   - No internet gateway or route table to declare; a public IP on the
//     NIC is what grants egress (default outbound access is retired, so
//     the public IPs we need for SSH are doing double duty).
package main

import (
	"fmt"

	"github.com/pulumi/pulumi-azure-native-sdk/compute/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/managedidentity/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/network/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v3"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

type node struct {
	name      string
	role      string
	privateIP string
	size      string // kept per-node: quota once forced uneven sizing (ADR 009)
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		// Your public IP in CIDR form. SSH, the Kubernetes API and the
		// gateway NodePorts are only reachable from here (same discipline as
		// AWS; `make check-ip` keeps it honest).
		myIP := cfg.Require("myIp")
		sshPublicKey := cfg.Require("sshPublicKey")
		location := cfg.Get("location")
		if location == "" {
			// westus2, not eastus, for one reason: the burstable B-series is
			// capacity-restricted in eastus but available here. The persistent
			// resource group (Pulumi state + Key Vault) stays in eastus — and
			// that split is a feature, not debt: state and backups living in a
			// different region from the cluster they describe is exactly what
			// you want when the cluster's region is what fails.
			location = "westus2"
		}

		// 2 vCPU / 4 GiB AMD burstable — the same shape AND the same
		// $0.0376/hr as the AWS t3a.medium this project ran on for three
		// weeks. Three nodes come to ~$0.128/hr all in, marginally CHEAPER
		// than AWS's ~$0.135/hr.
		//
		// Getting here took the long way round, and the history is the
		// lesson (ADR 009 + its addendum):
		//   1. On the FREE TRIAL this SKU failed 409 SkuNotAvailable
		//      "Capacity Restrictions" — the whole B-series was withheld.
		//      `az vm list-sizes` reported it available; only
		//      `az vm list-skus`'s `restrictions` field told the truth.
		//   2. Total Regional vCPUs was capped at 4, so three 2-core nodes
		//      were impossible regardless of family. That forced per-role
		//      sizing (2-core cp + two 1-core workers) as a workaround.
		//   3. The quota-increase request was DENIED (trial subscriptions
		//      generally are). Upgrading to pay-as-you-go lifted the cap to
		//      10 cores per region immediately.
		//   4. B-series remained restricted in eastus even after the
		//      upgrade — that one is genuine REGIONAL capacity, not
		//      entitlement — but is unrestricted in westus2. Hence the move.
		//
		// So the earlier "capacity" failures had two different causes wearing
		// the same error code: subscription entitlement (fixed by upgrading)
		// and regional capacity (fixed by moving). Worth separating, because
		// the remedies are nothing alike.
		//
		// NOTE the safety trade that came with the upgrade: pay-as-you-go
		// removes the spending limit that used to make overspend physically
		// impossible. Budget alerts only notify. `make destroy` is now the
		// only thing standing between a forgotten cluster and a real bill.
		vmSize := "Standard_B2als_v2"

		// Same address plan as the AWS and Hetzner layouts, so the cluster/
		// runbooks and Cilium's k8sServiceHost are unchanged.
		nodes := []node{
			{name: "k8s-cp-1", role: "control-plane", privateIP: "10.0.1.10", size: vmSize},
			{name: "k8s-worker-1", role: "worker", privateIP: "10.0.1.11", size: vmSize},
			{name: "k8s-worker-2", role: "worker", privateIP: "10.0.1.12", size: vmSize},
		}

		tags := pulumi.StringMap{
			"cluster":   pulumi.String("trk-k8s"),
			"lifecycle": pulumi.String("ephemeral"),
		}

		// The disposable half of ADR 008's boundary. `make destroy` deletes
		// this group; rg-trk-k8s-persistent (state, secrets, backups) carries
		// a CanNotDelete lock and is never part of a lab cycle.
		rg, err := resources.NewResourceGroup(ctx, "rg-trk-k8s-dev", &resources.ResourceGroupArgs{
			ResourceGroupName: pulumi.String("rg-trk-k8s-dev"),
			Location:          pulumi.String(location),
			Tags:              tags,
		})
		if err != nil {
			return err
		}

		// Identity the nodes run as, so in-cluster addons can reach Azure
		// APIs (Postgres backups to blob storage) without any credential in
		// the cluster — the managed-identity counterpart to AWS's instance
		// profile. Its role assignments come later, with the backup lab.
		nodeIdentity, err := managedidentity.NewUserAssignedIdentity(ctx, "id-trk-k8s-node", &managedidentity.UserAssignedIdentityArgs{
			ResourceName:      pulumi.String("id-trk-k8s-node"),
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			Tags:              tags,
		})
		if err != nil {
			return err
		}

		// NSG rules need explicit priorities (100-4096, lower wins) — unlike
		// an AWS security group, where rules are an unordered set. Note what
		// is ABSENT: no node-to-node rule. Azure's built-in
		// AllowVnetInBound (priority 65000) already permits all intra-VNet
		// traffic, so etcd/kubelet/VXLAN work with nothing declared. On AWS
		// the same thing required an explicit self-referencing rule.
		nsg, err := network.NewNetworkSecurityGroup(ctx, "nsg-trk-k8s", &network.NetworkSecurityGroupArgs{
			NetworkSecurityGroupName: pulumi.String("nsg-trk-k8s"),
			ResourceGroupName:        rg.Name,
			Location:                 rg.Location,
			Tags:                     tags,
			SecurityRules: network.SecurityRuleTypeArray{
				sshRule("AllowSshFromAdmin", 100, "22", myIP),
				sshRule("AllowApiServerFromAdmin", 110, "6443", myIP),
				sshRule("AllowGatewayHttpFromAdmin", 120, "30080", myIP),
				sshRule("AllowGatewayHttpsFromAdmin", 130, "30443", myIP),
			},
		})
		if err != nil {
			return err
		}

		vnet, err := network.NewVirtualNetwork(ctx, "vnet-trk-k8s", &network.VirtualNetworkArgs{
			VirtualNetworkName: pulumi.String("vnet-trk-k8s"),
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

		// Subnet as a separate resource, not inline on the VNet: declaring
		// both inline and separately makes them fight over the same child
		// and produces churn on every up.
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

		// Provider-agnostic node inventory — the contract (cluster/README.md).
		inventory := pulumi.Array{}
		for _, n := range nodes {
			n := n

			// Standard SKU + Static: Basic SKU public IPs were retired
			// (Sept 2025), and a dynamic address would change on every
			// deallocate — which would break the apiserver cert SAN and the
			// kubeconfig after any stop/start.
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
						nodeIdentity.ID(),
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
				OsProfile: &compute.OSProfileArgs{
					ComputerName: pulumi.String(n.name),
					// `ubuntu` keeps sshUser identical to the AWS inventory.
					// Azure rejects a list of reserved names (admin, root,
					// user, test...) but not this one — so the contract's
					// sshUser field costs us nothing here. It carries the
					// value as DATA, which is why a swap is possible at all.
					AdminUsername: pulumi.String("ubuntu"),
					LinuxConfiguration: &compute.LinuxConfigurationArgs{
						DisablePasswordAuthentication: pulumi.Bool(true),
						Ssh: &compute.SshConfigurationArgs{
							PublicKeys: compute.SshPublicKeyTypeArray{
								&compute.SshPublicKeyTypeArgs{
									Path:    pulumi.String("/home/ubuntu/.ssh/authorized_keys"),
									KeyData: pulumi.String(sshPublicKey),
								},
							},
						},
					},
				},
				StorageProfile: &compute.StorageProfileArgs{
					// StandardSSD, not Premium: a Premium P6 is $10.21/mo
					// each and three of them would be 15% of the trial
					// credits doing nothing.
					OsDisk: &compute.OSDiskArgs{
						CreateOption: pulumi.String(compute.DiskCreateOptionTypesFromImage),
						DiskSizeGB:   pulumi.Int(30),
						ManagedDisk: &compute.ManagedDiskParametersArgs{
							StorageAccountType: pulumi.String(compute.DiskStorageAccountTypes_StandardSSD_LRS),
						},
						DeleteOption: pulumi.String(compute.DiskDeleteOptionTypesDelete),
					},
					ImageReference: &compute.ImageReferenceArgs{
						Publisher: pulumi.String("Canonical"),
						Offer:     pulumi.String("ubuntu-24_04-lts"),
						Sku:       pulumi.String("server"),
						Version:   pulumi.String("latest"),
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
				"sshUser":   pulumi.String("ubuntu"),
			})
			ctx.Export(fmt.Sprintf("%s-public-ip", n.name), pip.IpAddress.Elem())
			ctx.Export(fmt.Sprintf("%s-private-ip", n.name), pulumi.String(n.privateIP))
		}

		// Everything downstream — prep-node.sh, bootstrap.sh, platform.sh —
		// consumes only this.
		ctx.Export("nodes", inventory)
		ctx.Export("resource-group", rg.Name)
		ctx.Export("node-identity-client-id", nodeIdentity.ClientId)
		return nil
	})
}

// One NSG rule allowing a single TCP port inbound from the admin CIDR.
// Azure wants direction, access, protocol and priority spelled out on every
// rule; AWS inferred all four from an ingress block.
func sshRule(name string, priority int, port, srcCIDR string) network.SecurityRuleTypeInput {
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
