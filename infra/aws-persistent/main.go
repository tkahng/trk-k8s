// Persistent AWS resources — the ones that must survive `make destroy`.
//
// WHY A SEPARATE PROJECT (ADR 008): a backup only earns its name if it
// outlives the thing it protects. In 7.4 the bucket lived in the node
// stack with ForceDestroy, so `pulumi destroy` reaped the backups it had
// just taken — fine within one session, fatal for Phase 8's
// rebuild-with-state drill and for restoring into a cluster that didn't
// exist when the backup was made.
//
// Pulumi has narrower tools for this (RetainOnDelete orphans the resource
// out of state; Protect makes `destroy` fail outright) — both fight the
// per-session teardown habit instead of modelling it. A lifecycle
// boundary is a stack boundary.
//
// Only ONE string crosses the seam: the IAM policy ARN. The ephemeral
// stack attaches it to the node role it owns.
package main

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/iam"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/s3"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// Fixed name so the CRD in apps/postgres-cnpg can reference it from
		// git (a generated suffix would change on every recreate).
		// NO ForceDestroy: a `pulumi destroy` here must fail on a non-empty
		// bucket rather than silently discard backups. Emptying it is a
		// deliberate act, not a side effect.
		backups, err := s3.NewBucketV2(ctx, "pg-backups", &s3.BucketV2Args{
			Bucket: pulumi.String("trk-k8s-pg-backups"),
			Tags: pulumi.StringMap{
				"cluster":   pulumi.String("trk-k8s"),
				"lifecycle": pulumi.String("persistent"),
			},
		})
		if err != nil {
			return err
		}

		// Versioning: WAL segments and base backups are write-once, but
		// versioning turns "someone/something deleted an object" from
		// data loss into a recoverable mistake.
		_, err = s3.NewBucketVersioningV2(ctx, "pg-backups-versioning", &s3.BucketVersioningV2Args{
			Bucket: backups.ID(),
			VersioningConfiguration: &s3.BucketVersioningV2VersioningConfigurationArgs{
				Status: pulumi.String("Enabled"),
			},
		})
		if err != nil {
			return err
		}

		// Barman prunes per its own retentionPolicy (7d), but abandoned
		// multipart uploads and old versions accumulate silently — this is
		// the janitor for what barman doesn't know about.
		_, err = s3.NewBucketLifecycleConfigurationV2(ctx, "pg-backups-lifecycle", &s3.BucketLifecycleConfigurationV2Args{
			Bucket: backups.ID(),
			Rules: s3.BucketLifecycleConfigurationV2RuleArray{
				&s3.BucketLifecycleConfigurationV2RuleArgs{
					Id:     pulumi.String("abort-incomplete-multipart"),
					Status: pulumi.String("Enabled"),
					Filter: &s3.BucketLifecycleConfigurationV2RuleFilterArgs{
						Prefix: pulumi.String(""),
					},
					AbortIncompleteMultipartUpload: &s3.BucketLifecycleConfigurationV2RuleAbortIncompleteMultipartUploadArgs{
						DaysAfterInitiation: pulumi.Int(7),
					},
				},
				&s3.BucketLifecycleConfigurationV2RuleArgs{
					Id:     pulumi.String("expire-noncurrent-versions"),
					Status: pulumi.String("Enabled"),
					Filter: &s3.BucketLifecycleConfigurationV2RuleFilterArgs{
						Prefix: pulumi.String(""),
					},
					NoncurrentVersionExpiration: &s3.BucketLifecycleConfigurationV2RuleNoncurrentVersionExpirationArgs{
						NoncurrentDays: pulumi.Int(30),
					},
				},
			},
		})
		if err != nil {
			return err
		}

		// A customer-managed policy rather than an inline one, because the
		// role it attaches to lives in the OTHER stack. Exporting an ARN
		// keeps the coupling to a single string.
		policy, err := iam.NewPolicy(ctx, "pg-backups-access", &iam.PolicyArgs{
			Name:        pulumi.String("trk-k8s-pg-backups-access"),
			Description: pulumi.String("barman-cloud read/write on the Postgres backup bucket"),
			Policy: backups.Arn.ApplyT(func(arn string) string {
				return fmt.Sprintf(`{
					"Version": "2012-10-17",
					"Statement": [{
						"Effect": "Allow",
						"Action": [
							"s3:ListBucket", "s3:GetBucketLocation",
							"s3:GetObject", "s3:PutObject", "s3:DeleteObject",
							"s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
						],
						"Resource": ["%s", "%s/*"]
					}]
				}`, arn, arn)
			}).(pulumi.StringOutput),
		})
		if err != nil {
			return err
		}

		ctx.Export("pg-backup-bucket", backups.Bucket)
		// The one value the ephemeral stack reads via StackReference.
		ctx.Export("pg-backup-policy-arn", policy.Arn)
		return nil
	})
}
