resource "cloudflare_dns_record" "origin" {
  for_each = var.records

  zone_id = var.zone_id
  name    = "${each.key}.${var.zone_name}"
  content = var.origin_ipv4[each.value.role]
  type    = "A"
  proxied = each.value.proxied
  ttl     = each.value.proxied ? 1 : 300
}
