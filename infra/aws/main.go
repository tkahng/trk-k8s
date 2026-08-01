package main

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/ec2"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/iam"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

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

		instanceType := "t3a.medium" // 2 vCPU, 4 GB — see docs/decisions/002
		az := "us-east-1a"

		// Same address plan as the Hetzner layout so the cluster/ runbooks
		// are identical: nodes live in 10.0.1.0/24 with fixed IPs.
		vpc, err := ec2.NewVpc(ctx, "k8s-vpc", &ec2.VpcArgs{
			CidrBlock:          pulumi.String("10.0.0.0/16"),
			EnableDnsSupport:   pulumi.Bool(true),
			EnableDnsHostnames: pulumi.Bool(true),
			Tags:               pulumi.StringMap{"Name": pulumi.String("k8s-vpc")},
		})
		if err != nil {
			return err
		}

		subnet, err := ec2.NewSubnet(ctx, "k8s-nodes", &ec2.SubnetArgs{
			VpcId:               vpc.ID(),
			CidrBlock:           pulumi.String("10.0.1.0/24"),
			AvailabilityZone:    pulumi.String(az),
			MapPublicIpOnLaunch: pulumi.Bool(true),
			Tags:                pulumi.StringMap{"Name": pulumi.String("k8s-nodes")},
		})
		if err != nil {
			return err
		}

		igw, err := ec2.NewInternetGateway(ctx, "k8s-igw", &ec2.InternetGatewayArgs{
			VpcId: vpc.ID(),
			Tags:  pulumi.StringMap{"Name": pulumi.String("k8s-igw")},
		})
		if err != nil {
			return err
		}

		routeTable, err := ec2.NewRouteTable(ctx, "k8s-rt", &ec2.RouteTableArgs{
			VpcId: vpc.ID(),
			Routes: ec2.RouteTableRouteArray{
				&ec2.RouteTableRouteArgs{
					CidrBlock: pulumi.String("0.0.0.0/0"),
					GatewayId: igw.ID(),
				},
			},
			Tags: pulumi.StringMap{"Name": pulumi.String("k8s-rt")},
		})
		if err != nil {
			return err
		}

		_, err = ec2.NewRouteTableAssociation(ctx, "k8s-rta", &ec2.RouteTableAssociationArgs{
			SubnetId:     subnet.ID(),
			RouteTableId: routeTable.ID(),
		})
		if err != nil {
			return err
		}

		// Unlike Hetzner (where the firewall only filters the public
		// interface), an AWS security group filters ALL traffic — so
		// node-to-node must be allowed explicitly (the self rule).
		sg, err := ec2.NewSecurityGroup(ctx, "k8s-sg", &ec2.SecurityGroupArgs{
			Name:        pulumi.String("k8s-sg"),
			Description: pulumi.String("kubeadm learning cluster"),
			VpcId:       vpc.ID(),
			Ingress: ec2.SecurityGroupIngressArray{
				&ec2.SecurityGroupIngressArgs{
					Description: pulumi.String("SSH from admin"),
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(22),
					ToPort:      pulumi.Int(22),
					CidrBlocks:  pulumi.StringArray{pulumi.String(myIP)},
				},
				&ec2.SecurityGroupIngressArgs{
					Description: pulumi.String("Kubernetes API from admin"),
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(6443),
					ToPort:      pulumi.Int(6443),
					CidrBlocks:  pulumi.StringArray{pulumi.String(myIP)},
				},
				&ec2.SecurityGroupIngressArgs{
					Description: pulumi.String("gateway HTTP from admin (cilium envoy, hostNetwork)"),
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(30080),
					ToPort:      pulumi.Int(30080),
					CidrBlocks:  pulumi.StringArray{pulumi.String(myIP)},
				},
				&ec2.SecurityGroupIngressArgs{
					Description: pulumi.String("gateway HTTPS from admin (cilium envoy, hostNetwork)"),
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(30443),
					ToPort:      pulumi.Int(30443),
					CidrBlocks:  pulumi.StringArray{pulumi.String(myIP)},
				},
				&ec2.SecurityGroupIngressArgs{
					Description: pulumi.String("all node-to-node traffic"),
					Protocol:    pulumi.String("-1"),
					FromPort:    pulumi.Int(0),
					ToPort:      pulumi.Int(0),
					Self:        pulumi.Bool(true),
				},
			},
			Egress: ec2.SecurityGroupEgressArray{
				&ec2.SecurityGroupEgressArgs{
					Protocol:   pulumi.String("-1"),
					FromPort:   pulumi.Int(0),
					ToPort:     pulumi.Int(0),
					CidrBlocks: pulumi.StringArray{pulumi.String("0.0.0.0/0")},
				},
			},
			Tags: pulumi.StringMap{"Name": pulumi.String("k8s-sg")},
		})
		if err != nil {
			return err
		}

		// Node IAM role: lets in-cluster AWS addons (EBS CSI driver) call the
		// EC2 API using the instance's own identity — no credential secrets
		// in the cluster. AWS-only concern; the cluster works without it
		// (ADR 002/003 — local-path storage needs none of this).
		nodeRole, err := iam.NewRole(ctx, "k8s-node", &iam.RoleArgs{
			Name: pulumi.String("k8s-node"),
			AssumeRolePolicy: pulumi.String(`{
				"Version": "2012-10-17",
				"Statement": [{
					"Effect": "Allow",
					"Principal": {"Service": "ec2.amazonaws.com"},
					"Action": "sts:AssumeRole"
				}]
			}`),
		})
		if err != nil {
			return err
		}

		_, err = iam.NewRolePolicyAttachment(ctx, "k8s-node-ebs-csi", &iam.RolePolicyAttachmentArgs{
			Role:      nodeRole.Name,
			PolicyArn: pulumi.String("arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"),
		})
		if err != nil {
			return err
		}

		// Postgres backups live in a SEPARATE stack that survives
		// `make destroy` (ADR 008) — a backup that dies with the cluster
		// isn't one. All this stack does is grant its nodes access, by
		// attaching the managed policy that stack exports.
		//
		// Credentials reach barman via IMDS on the node's own identity — the
		// same path the EBS CSI driver uses, and the one that taught us the
		// hop-limit-3 lesson in Phase 4. No access keys in the cluster.
		//
		// TRADE-OFF (ADR 007): instance-profile identity is NODE-scoped, so
		// any pod on the node can reach the backup bucket. IRSA scopes per
		// ServiceAccount but needs an OIDC provider kubeadm doesn't create.
		persistent, err := pulumi.NewStackReference(ctx, "tkahng/trk-k8s-aws-persistent/prod", nil)
		if err != nil {
			return err
		}
		_, err = iam.NewRolePolicyAttachment(ctx, "k8s-node-pg-backups", &iam.RolePolicyAttachmentArgs{
			Role:      nodeRole.Name,
			PolicyArn: persistent.GetStringOutput(pulumi.String("pg-backup-policy-arn")),
		})
		if err != nil {
			return err
		}
		// Passthrough so `pulumi stack output` here still answers "where do
		// backups go" without consulting the other stack.
		ctx.Export("pg-backup-bucket", persistent.GetStringOutput(pulumi.String("pg-backup-bucket")))

		nodeProfile, err := iam.NewInstanceProfile(ctx, "k8s-node", &iam.InstanceProfileArgs{
			Name: pulumi.String("k8s-node"),
			Role: nodeRole.Name,
		})
		if err != nil {
			return err
		}

		keyPair, err := ec2.NewKeyPair(ctx, "k8s-admin", &ec2.KeyPairArgs{
			KeyName:   pulumi.String("k8s-admin"),
			PublicKey: pulumi.String(sshPublicKey),
		})
		if err != nil {
			return err
		}

		// Latest Ubuntu 24.04 LTS amd64 from Canonical's owner account.
		ami, err := ec2.LookupAmi(ctx, &ec2.LookupAmiArgs{
			MostRecent: pulumi.BoolRef(true),
			Owners:     []string{"099720109477"},
			Filters: []ec2.GetAmiFilter{
				{Name: "name", Values: []string{"ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"}},
				{Name: "virtualization-type", Values: []string{"hvm"}},
			},
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
			instance, err := ec2.NewInstance(ctx, n.name, &ec2.InstanceArgs{
				Ami:                 pulumi.String(ami.Id),
				InstanceType:        pulumi.String(instanceType),
				SubnetId:            subnet.ID(),
				PrivateIp:           pulumi.String(n.privateIP),
				VpcSecurityGroupIds: pulumi.StringArray{sg.ID()},
				KeyName:             keyPair.KeyName,
				IamInstanceProfile:  nodeProfile.Name,
				// Pods must reach the instance metadata service (the EBS CSI
				// driver reads credentials and instance/AZ info there), and
				// each forwarding step burns one hop of the response TTL:
				// with Cilium's overlay it's node stack + pod veth, so 2 is
				// one too few — Hubble showed "TTL exceeded DROPPED" until
				// this was 3. Requiring IMDSv2 is current security baseline.
				MetadataOptions: &ec2.InstanceMetadataOptionsArgs{
					HttpTokens:              pulumi.String("required"),
					HttpPutResponseHopLimit: pulumi.Int(3),
				},
				RootBlockDevice: &ec2.InstanceRootBlockDeviceArgs{
					VolumeSize: pulumi.Int(20), // room for container images
					VolumeType: pulumi.String("gp3"),
				},
				Tags: pulumi.StringMap{
					"Name":    pulumi.String(n.name),
					"cluster": pulumi.String("k8s"),
					"role":    pulumi.String(n.role),
				},
			})
			if err != nil {
				return err
			}

			ctx.Export(fmt.Sprintf("%s-public-ip", n.name), instance.PublicIp)
			ctx.Export(fmt.Sprintf("%s-private-ip", n.name), pulumi.String(n.privateIP))

			inventory = append(inventory, pulumi.Map{
				"name":      pulumi.String(n.name),
				"role":      pulumi.String(n.role),
				"publicIp":  instance.PublicIp,
				"privateIp": pulumi.String(n.privateIP),
				"sshUser":   pulumi.String("ubuntu"), // Ubuntu AMIs log in as ubuntu
			})
		}

		ctx.Export("nodes", inventory)
		ctx.Export("vpc-id", vpc.ID())
		return nil
	})
}
