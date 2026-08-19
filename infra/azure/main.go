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
			// eastus: colocated with rg-trk-k8s-persistent, and the only
			// place a working size was actually proven. westus2 looked
			// better on paper (B-series SKUs visible) and turned out to be
			// a dead end — see the size comment below.
			location = "eastus"
		}

		// 2 vCPU / 4 GiB AMD — uniform across all three nodes, matching the
		// AWS t3a.medium shape so drill timings stay comparable to the
		// baseline. NOT burstable: no burstable SKU is reachable on this
		// subscription, and finding that out took three separate walls.
		//
		// AZURE GATES COMPUTE AT **THREE INDEPENDENT LAYERS**, and all three
		// must align before a VM can exist. This is the real lesson:
		//
		//   1. Total Regional vCPUs — was 4 on the free trial; pay-as-you-go
		//      lifted it to 10 per region.
		//   2. Per-FAMILY vCPUs — a separate counter per VM family.
		//      `standardBasv2Family` is **0** in both eastus and westus2, so
		//      B2als_v2 fails even with regional headroom. Note the trap:
		//      "Standard BS Family vCPUs" shows 10, but that is B-series
		//      *v1*, a different counter entirely.
		//   3. SKU availability in the region — B2als_v2 is capacity-
		//      restricted in eastus but listed in westus2 (layer 3 passes,
		//      layer 2 still blocks); and B2s/B2ms, whose family quota IS
		//      10, are not offered in either region at all. A family quota
		//      can exist for SKUs that no longer ship.
		//
		// So "SkuNotAvailable" and "exceeding approved quota" are different
		// failures with different remedies (move region / raise quota), and a
		// third state exists where quota is fine and the SKU simply isn't
		// sold. `az vm list-sizes` sees none of this; `az vm list-skus`
		// --all=false covers layer 3 only; `az vm list-usage` covers 1 and 2.
		//
		// D2als_v7: Dalsv7 family quota 10, unrestricted in eastus, proven
		// deployed. $0.0804/hr each -> ~$0.256/hr all in, versus AWS's
		// ~$0.135/hr. Roughly 1.9x for identical specs, because the cheap
		// burstable tier is simply out of reach here.
		cpSize := "Standard_D2als_v7"
		// Workers upsized in drill 2 (2026-08-18): two 4Gi workers could not
		// hold the platform stack plus even two NetBox replicas at their
		// true 2Gi boot footprint — three node-wedges in one afternoon were
		// the same arithmetic finding three disguises (dishonest requests,
		// an RWO media-volume pin, request-less platform pods). 8Gi workers
		// end the class. Quota math is exact: 2 (cp) + 4 + 4 = 10 of the
		// family's 10 vCPUs.
		workerSize := "Standard_D4als_v7"

		// Same address plan as the AWS and Hetzner layouts, so the cluster/
		// runbooks and Cilium's k8sServiceHost are unchanged.
		nodes := []node{
			{name: "k8s-cp-1", role: "control-plane", privateIP: "10.0.1.10", size: cpSize},
			{name: "k8s-worker-1", role: "worker", privateIP: "10.0.1.11", size: workerSize},
			{name: "k8s-worker-2", role: "worker", privateIP: "10.0.1.12", size: workerSize},
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

		// The node identity is NOT created here (ADR 009 addendum). It lives in
		// rg-trk-k8s-persistent alongside the data it grants access to,
		// because a CanNotDelete lock on that group blocks deleting role
		// assignments scoped inside it — so an ephemeral stack owning the
		// grant could never be destroyed (409 ScopeLocked). foundation.sh
		// owns identity + grant; this stack only attaches it.
		nodeIdentityID := cfg.Require("nodeIdentityId")

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
					// Premium (P6), reversing the trial-era StandardSSD
					// choice. StandardSSD has NO latency SLA, and etcd
					// fsyncs every write: on the 2026-08-17 bring-up the
					// apiserver dropped two ~1MB helm writes and etcd
					// logged 70 slow-apply warnings in 30 minutes. Premium
					// buys single-digit-ms latency + 3500 burst IOPS for
					// ~$10/mo per disk — and DeleteOption: Delete means it
					// only bills while the cluster exists, which (ADR 011
					// era: up-when-needed, credits until Sept 4) is hours,
					// not months. Workers get it too: local-path PVs (the
					// Postgres volumes) live on the OS disk.
					OsDisk: &compute.OSDiskArgs{
						CreateOption: pulumi.String(compute.DiskCreateOptionTypesFromImage),
						DiskSizeGB:   pulumi.Int(64),
						ManagedDisk: &compute.ManagedDiskParametersArgs{
							StorageAccountType: pulumi.String(compute.DiskStorageAccountTypes_Premium_LRS),
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
		ctx.Export("node-identity", pulumi.String(nodeIdentityID))
		// What CNPG's barmanObjectStore destinationPath must point at.
		ctx.Export("pg-backup-url", pulumi.Sprintf("https://%s.blob.core.windows.net/%s",
			cfg.Require("backupStorageAccount"), cfg.Require("backupContainer")))
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
