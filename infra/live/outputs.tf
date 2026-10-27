# CI reads content_bucket and cdn_id to upload files and clear the cache.
output "site_url" {
  value = module.static_site.site_url
}

output "content_bucket" {
  value = module.static_site.content_bucket
}

output "cdn_id" {
  value = module.static_site.cdn_id
}

output "dashboard_url" {
  value = module.monitoring.dashboard_url
}
