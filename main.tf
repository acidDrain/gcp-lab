provider "google" {
  project = var.project
  region  = var.region
}

locals {
  project_id = var.project
}

###############
# Data Sources
###############

data "google_compute_zones" "available" {
  project = local.project_id
  region  = var.region
}

resource "google_compute_project_metadata_item" "oslogin" {
  key   = "enable-oslogin"
  value = "true"
}

module "vpc" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 4.0"
  project_id   = local.project_id
  network_name = "gcp-lab-vpc"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name   = "sub1"
      subnet_ip     = "10.0.0.0/24"
      subnet_region = var.region
    },
    {
      subnet_name   = "sub2"
      subnet_ip     = "10.0.10.0/24"
      subnet_region = var.region
    },
    {
      subnet_name   = "sub3"
      subnet_ip     = "10.0.20.0/24"
      subnet_region = var.region
    },
    {
      subnet_name   = "sub4"
      subnet_ip     = "10.0.30.0/24"
      subnet_region = var.region
    }
  ]

  routes = [
    {
      name              = "egress-internet"
      description       = "route through IGW to access internet"
      destination_range = "0.0.0.0/0"
      tags              = "egress-inet"
      next_hop_internet = "true"
    },
  ]
}

module "firewall_rules" {
  source       = "terraform-google-modules/network/google//modules/firewall-rules"
  project_id   = local.project_id
  network_name = module.vpc.network_name

  rules = [{
    name                    = "allow-ssh-ingress"
    description             = null
    direction               = "INGRESS"
    priority                = null
    ranges                  = ["0.0.0.0/0"]
    source_tags             = null
    source_service_accounts = null
    target_tags             = [module.vpc.subnets_names[0], module.vpc.subnets_names[1]]
    target_service_accounts = null
    allow = [{
      protocol = "tcp"
      ports    = ["22"]
    }]
    deny = []
    log_config = {
      metadata = "INCLUDE_ALL_METADATA"
    }
    },
    {
      name                    = "allow-icmp-ingress"
      description             = null
      direction               = "INGRESS"
      priority                = null
      ranges                  = ["0.0.0.0/0"]
      source_tags             = null
      source_service_accounts = null
      target_tags             = [module.vpc.subnets_names[0], module.vpc.subnets_names[1]]
      target_service_accounts = null
      allow = [{
        protocol = "icmp"
        ports    = []
      }]
      deny = []
      log_config = {
        metadata = "INCLUDE_ALL_METADATA"
      }
    }
  ]
}

resource "google_compute_router" "default" {
  name    = "lb-http-router"
  network = module.vpc.network_name
  region  = var.region
}


module "cloud-nat" {
  source     = "terraform-google-modules/cloud-nat/google"
  version    = "1.4.0"
  router     = google_compute_router.default.name
  project_id = local.project_id
  region     = var.region
  name       = "cloud-nat-lb-http-router"
}

data "template_file" "group-startup-script" {
  template = file(format("%s/gceme.sh.tpl", path.module))

  vars = {
    PROXY_PATH = ""
  }
}

module "mig_template" {
  source     = "terraform-google-modules/vm/google//modules/instance_template"
  version    = "6.2.0"
  network    = module.vpc.network_self_link
  subnetwork = module.vpc.subnets_self_links[2]
  service_account = {
    email  = ""
    scopes = ["cloud-platform"]
  }
  name_prefix          = module.vpc.network_name
  startup_script       = data.template_file.group-startup-script.rendered
  source_image_project = "rhel-cloud"
  source_image_family  = "rhel-8"
  tags = [
    module.vpc.network_name,
    module.cloud-nat.router_name,
    "http-service"
  ]
}

module "mig" {
  source            = "terraform-google-modules/vm/google//modules/mig"
  version           = "6.2.0"
  project_id        = local.project_id
  instance_template = module.mig_template.self_link
  region            = var.region
  hostname          = module.vpc.network_name
  target_size       = 2
  named_ports = [{
    name = "http",
    port = 80
  }]
  network    = module.vpc.network_self_link
  subnetwork = module.vpc.subnets_self_links[2]
}

module "gce-lb-http" {
  source            = "GoogleCloudPlatform/lb-http/google"
  name              = "mig-http-lb"
  project           = local.project_id
  target_tags       = ["http-service"]
  firewall_networks = [module.vpc.network_name]
  http_forward      = true
  https_redirect    = false
  ssl               = false

  backends = {
    default = {
      description                     = null
      protocol                        = "HTTP"
      port                            = 80
      port_name                       = "http"
      timeout_sec                     = 10
      connection_draining_timeout_sec = null
      enable_cdn                      = false
      security_policy                 = google_compute_security_policy.policy.name
      session_affinity                = null
      affinity_cookie_ttl_sec         = null
      custom_request_headers          = null
      custom_response_headers         = null
      create_url_map                  = true

      health_check = {
        check_interval_sec  = null
        timeout_sec         = null
        healthy_threshold   = null
        unhealthy_threshold = null
        request_path        = "/"
        port                = 80
        host                = null
        logging             = null
      }

      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      groups = [
        {
          group                        = module.mig.instance_group
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        }
      ]

      iap_config = {
        enable               = false
        oauth2_client_id     = ""
        oauth2_client_secret = ""
      }
    }
  }
}

resource "google_compute_instance" "sub1-rhel" {
  name         = "sub1-rhel"
  machine_type = "n1-standard-1"
  zone         = "us-central1-a"

  tags = [module.vpc.subnets_names[0]]


  boot_disk {
    initialize_params {
      image = "rhel-cloud/rhel-8"
    }
  }

  // Local SSD disk
  scratch_disk {
    interface = "SCSI"
  }

  network_interface {
    subnetwork = module.vpc.subnets_names[0]

    access_config {}
  }


  allow_stopping_for_update = true

  metadata = {
    enable-oslogin = true
  }
  # metadata_startup_script = "echo hi > /test.txt"

}

resource "google_compute_security_policy" "policy" {
  name = "owasp-sqli-policy"

  rule {
    action   = "deny(403)"
    priority = "0"
    match {
      expr {
        expression = "inIpRange(origin.ip, '0.0.0.0/0') && evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
    description = "block sqli"
  }

  rule {
    action   = "allow"
    priority = "1"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "allow everything else"
  }

  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default allow"
  }
}


resource "google_dns_managed_zone" "gcp-lab" {
  name     = "lab-zone"
  dns_name = "lab.elasticplayground.dev."
}


resource "google_dns_record_set" "http" {
  name = "http.${google_dns_managed_zone.gcp-lab.dns_name}"
  type = "A"
  ttl  = 300

  managed_zone = google_dns_managed_zone.gcp-lab.name

  rrdatas = [module.gce-lb-http.external_ip]
}


