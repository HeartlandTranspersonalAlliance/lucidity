output "records" {
  description = "Managed Cloudflare A records keyed by complete hostname."
  value = {
    for _, record in cloudflare_dns_record.origin :
    record.name => {
      content = record.content
      id      = record.id
      proxied = record.proxied
      ttl     = record.ttl
      type    = record.type
    }
  }
}
