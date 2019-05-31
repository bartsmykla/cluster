variable "do_token" {
}

variable "do_dns_token" {
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_kubernetes_cluster" "smykla-prod" {
  name    = "smykla-prod"
  region  = "lon1"
  version = "1.14.2-do.0"
  tags    = ["smykla-prod"]

  node_pool {
    name       = "worker-pool"
    size       = "s-1vcpu-2gb"
    node_count = 2
  }
}

locals {
  k8s = {
    host = digitalocean_kubernetes_cluster.smykla-prod.endpoint
    client = {
      certificate = base64decode(tolist(digitalocean_kubernetes_cluster.smykla-prod.kube_config)[0].client_certificate)
      key         = base64decode(tolist(digitalocean_kubernetes_cluster.smykla-prod.kube_config)[0].client_key)
    }
    cluster = {
      ca = {
        certificate = base64decode(tolist(digitalocean_kubernetes_cluster.smykla-prod.kube_config)[0].cluster_ca_certificate)
      }
    }
  }

  helm = {
    tiller = {
      name      = "terraform-tiller"
      namespace = "kube-system"
    }
  }

  cert-manager = {
    crds-path = "https://raw.githubusercontent.com/jetstack/cert-manager/release-0.8/deploy/manifests/00-crds.yaml"
  }
  temp_kubeconfig_path = "/tmp/kubeconfig_qwerty9876"
}

provider "kubernetes" {
  host = local.k8s.host

  client_certificate     = local.k8s.client.certificate
  client_key             = local.k8s.client.key
  cluster_ca_certificate = local.k8s.cluster.ca.certificate
}

data "external" "droplet_ids" {
  program = [join("", [path.module, "/scripts/get_droplet_ids.sh"])]

  depends_on = [
    digitalocean_kubernetes_cluster.smykla-prod
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

  droplet_ids = jsondecode(data.external.droplet_ids.result.droplet_ids)
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
    name = kubernetes_service_account.tiller.metadata[0].name
  }

  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind = "ServiceAccount"
    name = kubernetes_service_account.tiller.metadata[0].name

    api_group = ""
    namespace = kubernetes_service_account.tiller.metadata[0].namespace
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
  service_account = kubernetes_service_account.tiller.metadata[0].name
  namespace       = kubernetes_service_account.tiller.metadata[0].namespace
  tiller_image    = "gcr.io/kubernetes-helm/tiller:v2.14.0"
}

data "helm_repository" "stable" {
  name = "stable"
  url  = "https://kubernetes-charts.storage.googleapis.com"
}

resource "helm_release" "nginx-ingress" {
  name       = "nginx-ingress"
  repository = data.helm_repository.stable.metadata[0].name
  chart      = "nginx-ingress"
  version    = "1.6.15"
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
    name  = "controller.service.nodePorts.https"
    value = "32169"
  }

  timeout = 600

  depends_on = [
    kubernetes_service_account.tiller,
    kubernetes_cluster_role_binding.tiller
  ]
}

resource "null_resource" "cert-manager-crds" {
  provisioner "local-exec" {
    command = join("", [
      path.cwd,
      "/scripts/kubectl_operations.sh --cluster-id ",
      digitalocean_kubernetes_cluster.smykla-prod.id,
      " --kubeconfig-path ",
      local.temp_kubeconfig_path,
      " --crds-path ",
      local.cert-manager.crds-path
    ])
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = join("", ["rm ", local.temp_kubeconfig_path, " || true"])
  }
}

data "helm_repository" "jetstack" {
  name = "jetstack"
  url  = "https://charts.jetstack.io"
}

resource "helm_release" "cert-manager" {
  name       = "cert-manager"
  repository = data.helm_repository.jetstack.url
  chart      = "cert-manager"
  namespace  = "cert-manager"

  depends_on = [
    kubernetes_service_account.tiller,
    kubernetes_cluster_role_binding.tiller,
    null_resource.cert-manager-crds
  ]
}

resource "kubernetes_secret" "do-dns-token" {
  metadata {
    name      = "do-dns-token"
    namespace = "cert-manager"
  }
  data = {
    access-token = var.do_dns_token
  }
  depends_on = [
    helm_release.cert-manager
  ]
}

resource "null_resource" "cluster-issuer" {
  provisioner "local-exec" {
    command = join("", [
      path.cwd,
      "/scripts/kubectl_operations.sh --cluster-id ",
      digitalocean_kubernetes_cluster.smykla-prod.id,
      " --kubeconfig-path ",
      local.temp_kubeconfig_path,
      " --create-cluster-issuers"
    ])
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = join("", ["rm ", local.temp_kubeconfig_path, " || true"])
  }

  depends_on = [
    helm_release.cert-manager
  ]
}
