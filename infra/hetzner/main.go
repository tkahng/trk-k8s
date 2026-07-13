package main

import (
	"fmt"
	"strconv"

	"github.com/pulumi/pulumi-hcloud/sdk/go/hcloud"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// The hcloud provider exposes resource IDs as strings, but several fields
// (NetworkId, FirewallIds, PlacementGroupId) want integers.
func intID(id pulumi.IDOutput) pulumi.IntOutput {
	return id.ApplyT(func(s string) (int, error) {
		return strconv.Atoi(s)
	}).(pulumi.IntOutput)
}

type node struct {
	name      string
	role      string
	privateIP string
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		// Your public IP in CIDR form (e.g. 203.0.113.7/32). SSH and the
		// Kubernetes API are only reachable from here.
		myIP := cfg.Require("myIp")
		sshPublicKey := cfg.Require("sshPublicKey")

		location := "fsn1"        // Falkenstein — CX series is EU-only
		serverType := "cx23"      // 2 vCPU x86, 4 GB RAM (see docs/decisions/001)
		image := "ubuntu-24.04"

		sshKey, err := hcloud.NewSshKey(ctx, "k8s-admin", &hcloud.SshKeyArgs{
			Name:      pulumi.String("k8s-admin"),
			PublicKey: pulumi.String(sshPublicKey),
		})
		if err != nil {
			return err
		}

		// Node-to-node traffic (etcd, kubelet, pod network) stays on this
		// private network. Hetzner firewalls only filter the public
		// interface, so nothing here blocks cluster-internal traffic.
		network, err := hcloud.NewNetwork(ctx, "k8s-net", &hcloud.NetworkArgs{
			Name:    pulumi.String("k8s-net"),
			IpRange: pulumi.String("10.0.0.0/16"),
		})
		if err != nil {
			return err
		}

		subnet, err := hcloud.NewNetworkSubnet(ctx, "k8s-nodes", &hcloud.NetworkSubnetArgs{
			NetworkId:   intID(network.ID()),
			Type:        pulumi.String("cloud"),
			NetworkZone: pulumi.String("eu-central"),
			IpRange:     pulumi.String("10.0.1.0/24"),
		})
		if err != nil {
			return err
		}

		firewall, err := hcloud.NewFirewall(ctx, "k8s-fw", &hcloud.FirewallArgs{
			Name: pulumi.String("k8s-fw"),
			Rules: hcloud.FirewallRuleArray{
				&hcloud.FirewallRuleArgs{
					Description: pulumi.String("SSH from admin"),
					Direction:   pulumi.String("in"),
					Protocol:    pulumi.String("tcp"),
					Port:        pulumi.String("22"),
					SourceIps:   pulumi.StringArray{pulumi.String(myIP)},
				},
				&hcloud.FirewallRuleArgs{
					Description: pulumi.String("Kubernetes API from admin"),
					Direction:   pulumi.String("in"),
					Protocol:    pulumi.String("tcp"),
					Port:        pulumi.String("6443"),
					SourceIps:   pulumi.StringArray{pulumi.String(myIP)},
				},
				&hcloud.FirewallRuleArgs{
					Description: pulumi.String("ICMP (ping)"),
					Direction:   pulumi.String("in"),
					Protocol:    pulumi.String("icmp"),
					SourceIps: pulumi.StringArray{
						pulumi.String("0.0.0.0/0"),
						pulumi.String("::/0"),
					},
				},
			},
		})
		if err != nil {
			return err
		}

		// Spread nodes across physical hosts so one host failure can't take
		// out the whole cluster.
		placementGroup, err := hcloud.NewPlacementGroup(ctx, "k8s-spread", &hcloud.PlacementGroupArgs{
			Name: pulumi.String("k8s-spread"),
			Type: pulumi.String("spread"),
		})
		if err != nil {
			return err
		}

		nodes := []node{
			{name: "k8s-cp-1", role: "control-plane", privateIP: "10.0.1.10"},
			{name: "k8s-worker-1", role: "worker", privateIP: "10.0.1.11"},
			{name: "k8s-worker-2", role: "worker", privateIP: "10.0.1.12"},
		}

		// Provider-agnostic node inventory: every infra stack (hetzner, aws,
		// on-prem, ...) exports this exact shape, and the cluster/ layer
		// consumes only this. See cluster/README.md for the contract.
		inventory := pulumi.Array{}

		for _, n := range nodes {
			server, err := hcloud.NewServer(ctx, n.name, &hcloud.ServerArgs{
				Name:             pulumi.String(n.name),
				ServerType:       pulumi.String(serverType),
				Image:            pulumi.String(image),
				Location:         pulumi.String(location),
				SshKeys:          pulumi.StringArray{sshKey.Name},
				FirewallIds:      pulumi.IntArray{intID(firewall.ID())},
				PlacementGroupId: intID(placementGroup.ID()),
				Labels: pulumi.StringMap{
					"cluster": pulumi.String("k8s"),
					"role":    pulumi.String(n.role),
				},
			})
			if err != nil {
				return err
			}

			// Attach to the private network with a fixed IP so the kubeadm
			// runbook can use stable addresses.
			_, err = hcloud.NewServerNetwork(ctx, n.name+"-net", &hcloud.ServerNetworkArgs{
				ServerId:  intID(server.ID()),
				NetworkId: intID(network.ID()),
				Ip:        pulumi.String(n.privateIP),
			}, pulumi.DependsOn([]pulumi.Resource{subnet}))
			if err != nil {
				return err
			}

			ctx.Export(fmt.Sprintf("%s-public-ip", n.name), server.Ipv4Address)
			ctx.Export(fmt.Sprintf("%s-private-ip", n.name), pulumi.String(n.privateIP))

			inventory = append(inventory, pulumi.Map{
				"name":      pulumi.String(n.name),
				"role":      pulumi.String(n.role),
				"publicIp":  server.Ipv4Address,
				"privateIp": pulumi.String(n.privateIP),
				"sshUser":   pulumi.String("root"), // Hetzner images log in as root
			})
		}

		ctx.Export("nodes", inventory)
		ctx.Export("network-id", network.ID())
		return nil
	})
}
