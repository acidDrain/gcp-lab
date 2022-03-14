output "sub1-host-ip" {
  value = google_compute_instance.sub1-rhel.network_interface.0.access_config.0.nat_ip
}

output "http-lb-ip" {
  value = module.gce-lb-http.external_ip
}

