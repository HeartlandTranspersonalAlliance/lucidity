# Cost and addressing decisions

This deployment uses Cloudflare for authoritative DNS and optional HTTP proxying. The
AWS origin uses direct Elastic IP connectivity for the two EC2 nodes.

## DNS and public addresses

Use one stable Elastic IP per node and reuse the worker address for every hosted
service. Any number of application records can share that worker origin address.

| Record | Target | Cloudflare mode |
|---|---|---|
| `coolify.heartlandta.org` | controller Elastic IP | Proxied |
| `apps.heartlandta.org` | worker Elastic IP | Proxied |
| `*.apps.heartlandta.org` | worker Elastic IP | Proxied |
| `matrix.heartlandta.org` | worker Elastic IP | Proxied |

Cloudflare returns its shared anycast addresses to clients for proxied records and
connects to the Elastic IP origin. Use HTTPS port 443 for Matrix client and federation
traffic through Cloudflare's standard proxy. If the Matrix user identifier uses the zone apex,
serve the standard `/.well-known/matrix/client` and `/.well-known/matrix/server`
delegation documents from that hostname and delegate federation to
`matrix.example.org:443`.

The controller and worker keep separate Elastic IPs. This preserves management access
while application builds, Matrix, PostgreSQL, and bridges consume worker memory and
I/O. Revisit consolidation after measured utilization and successful restore drills.

## IPv6 decision

Keep public IPv4 connectivity for both nodes. Discord bridge endpoints and required
image registries currently depend on IPv4 egress. The two Elastic IPs provide that path
at a lower base cost than AWS DNS64/NAT64 through a NAT Gateway. Cloudflare supplies
shared IPv4 and IPv6 anycast addresses to website and Matrix clients at the frontend.

Dual-stack remains a future inbound enhancement after the external dependencies offer
a complete IPv6 egress path.

## Current low-idle-cost choices

- The AMD64 controller uses `t3a.small`; the worker starts at `t3a.medium` and moves
  to `t3a.large` only when measured memory peaks require it.
- T3a burstable instances use fixed-cost standard credits.
- The controller and worker share one Availability Zone by default, keeping their
  private traffic free of cross-AZ data-transfer charges.
- gp3 root volumes use included baseline IOPS and throughput.
- Direct EC2 networking and Coolify-managed routing provide the ingress and service
  layers.
- EC2 basic monitoring supplies the one-minute
  status checks and five-minute CPU and credit metrics used by the alarms.
- VPC Flow Logs capture rejected traffic only and expire after 30 days.
- AWS Backup keeps 7 daily incremental recovery points in warm regional storage.
- The bundled runtime secret uses the AWS managed `aws/secretsmanager` KMS key, so it
  does not create another customer-managed key with a monthly storage charge.
- The optional account-wide AWS Budget alerts at 80 percent actual spend, 100 percent
  forecasted spend, and 100 percent actual spend without enabling automated actions.

Monitoring-only AWS Budgets and their notifications are free. Budget data is not
real-time, and forecast alerts need enough usage history to become available, so the
budget complements resource-health alarms rather than replacing them. Its account-wide
scope catches untagged or accidentally created resources outside the lucidity stack.

Review instance memory, CPU credits, gp3 consumption, backup storage, CloudWatch Logs,
and internet egress after the first month. Resize only from measured peaks: the Matrix
database, media, bridge processes, application containers, and Coolify builds share the
worker's memory and disk budget.

Using the us-east-2 prices reviewed on 2026-08-16, the conservative two-node annual
baseline is about USD 809.66: USD 494.06 for on-demand compute, USD 87.60 for two
public IPv4 addresses, USD 115.20 for 120 GiB of gp3, USD 24.00 for the AMI and alarm
customer-managed KMS keys, USD 4.80 for the runtime secret, and USD 84.00 for 140 GiB
of snapshot storage. This leaves about USD 290.34 of the USD 1,100 gross annual budget
for flow-log ingestion, incremental backup churn, ECR, S3 state, internet transfer,
and growth. The budget intentionally excludes credits and refunds, while the expiring
grant credits reduce the invoice separately.

## References

- [Cloudflare proxied DNS records](https://developers.cloudflare.com/dns/proxy-status/)
- [Cloudflare proxy port support](https://developers.cloudflare.com/fundamentals/reference/network-ports/)
- [Matrix server discovery and delegation](https://spec.matrix.org/latest/server-server-api/#server-discovery)
- [AWS public IPv4 pricing](https://aws.amazon.com/vpc/pricing/)
- [AWS IPv6-to-IPv4 connectivity through DNS64 and NAT64](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-nat64-dns64.html)
- [EC2 basic and detailed monitoring](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/manage-detailed-monitoring.html)
- [AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)
- [AWS Budgets best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html)
