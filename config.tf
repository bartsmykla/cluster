variable "do_token" {
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_kubernetes_cluster" "smykla-prod" {
  name    = "smykla-prod"
  region  = "lon1"
  version = "1.14.2-do.0"
  tags    = ["k8s", "production"]

  node_pool {
    name       = "worker-pool"
    size       = "s-1vcpu-2gb"
    node_count = 2
  }
}

locals {
  kubeconfig = tolist(digitalocean_kubernetes_cluster.smykla-prod.kube_config)[0]
}

locals {
  k8s = {
    host = digitalocean_kubernetes_cluster.smykla-prod.endpoint
    client = {
      certificate = base64decode(local.kubeconfig.client_certificate)
      key         = base64decode(local.kubeconfig.client_key)
    }
    cluster = {
      ca = {
        certificate = base64decode(local.kubeconfig.cluster_ca_certificate)
      }
    }
  }
}

provider "kubernetes" {
  host = local.k8s.host

  client_certificate     = local.k8s.client.certificate
  client_key             = local.k8s.client.key
  cluster_ca_certificate = local.k8s.cluster.ca.certificate
}

data "http" "droplets" {
  url = "https://api.digitalocean.com/v2/droplets"

  request_headers = {
    Content-Type  = "application/json"
    Authorization = "Bearer ${var.do_token}"
  }

  depends_on = [
    digitalocean_kubernetes_cluster.smykla-prod
  ]
}

locals {
  droplet_ids = [
    for droplet in jsondecode(data.http.droplets.body).droplets :
    droplet.id
    if contains(droplet.tags, "k8s:${digitalocean_kubernetes_cluster.smykla-prod.id}")
  ]
}

resource "digitalocean_loadbalancer" "smykla-prod-public-lb" {
  name   = "loadbalancer-1"
  region = "lon1"

  forwarding_rule {
    entry_port     = 80
    entry_protocol = "tcp"

    target_port     = 32192
    target_protocol = "tcp"
  }

  forwarding_rule {
    entry_port     = 443
    entry_protocol = "tcp"

    target_port     = 32169
    target_protocol = "tcp"
  }

  healthcheck {
    port     = 32192
    protocol = "tcp"
  }

  droplet_ids = local.droplet_ids
}

output "digitalocean_kubernetes_cluster" {
  value = digitalocean_kubernetes_cluster.smykla-prod
}

output "digitalocean_loadbalancer" {
  value = digitalocean_loadbalancer.smykla-prod-public-lb
}

locals {
  helm = {
    tiller = {
      name      = "terraform-tiller"
      namespace = "kube-system"
    }
  }
}

resource "kubernetes_service_account" "tiller" {
  metadata {
    name      = local.helm.tiller.name
    namespace = local.helm.tiller.namespace
  }

  automount_service_account_token = true
}

resource "kubernetes_cluster_role_binding" "tiller" {
  metadata {
    name = kubernetes_service_account.tiller.metadata.0.name
  }

  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind = "ServiceAccount"
    name = kubernetes_service_account.tiller.metadata.0.name

    api_group = ""
    namespace = kubernetes_service_account.tiller.metadata.0.namespace
  }
}

provider "helm" {
  kubernetes {
    host = local.k8s.host

    client_certificate     = local.k8s.client.certificate
    client_key             = local.k8s.client.key
    cluster_ca_certificate = local.k8s.cluster.ca.certificate
  }

  debug           = true
  install_tiller  = true
  service_account = kubernetes_service_account.tiller.metadata.0.name
  namespace       = kubernetes_service_account.tiller.metadata.0.namespace
  tiller_image    = "gcr.io/kubernetes-helm/tiller:v2.14.0"
}

data "helm_repository" "stable" {
  name = "stable"
  url  = "https://kubernetes-charts.storage.googleapis.com"
}

resource "helm_release" "example" {
  name       = "nginx-ingress"
  repository = data.helm_repository.stable.metadata.0.name
  chart      = "nginx-ingress"
  namespace  = "kube-system"

  values = [
    templatefile("helm/nginx-ingress/values.yml", { external_ip : digitalocean_loadbalancer.smykla-prod-public-lb.ip })
  ]

  set {
    name  = "rbac.create"
    value = "true"
  }

  set {
    name  = "controller.service.type"
    value = "NodePort"
  }

  set {
    name  = "controller.service.loadBalancerIP"
    value = digitalocean_loadbalancer.smykla-prod-public-lb.ip
  }

  set {
    name  = "controller.service.nodePorts.http"
    value = "32192"
  }

  set {
    name  = "controller.service.nodePorts.http"
    value = "32169"
  }

  timeout = 600

  depends_on = [
    kubernetes_service_account.tiller,
    kubernetes_cluster_role_binding.tiller
  ]
}
