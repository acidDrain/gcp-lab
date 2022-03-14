output "sub1-host-ip" {
  value = google_compute_instance.sub1-rhel.network_interface.0.access_config.0.nat_ip
}

output "sub1-ssh" {
  value = google_dns_record_set.ssh.name
}

output "http-lb-ip" {
  value = module.gce-lb-http.external_ip
}

output "http-lb-name" {
  value = google_dns_record_set.http.name
}
