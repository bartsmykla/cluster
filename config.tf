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

locals {
  temp_droplets_json_path = "/tmp/droplets_qwerty9876.json"
}

resource "null_resource" "get_droplets" {
  provisioner "local-exec" {
    command = "${path.cwd}/scripts/get_droplets.sh --json-file-path ${local.temp_droplets_json_path}"
  }

  provisioner "local-exec" {

    command = "rm ${local.temp_droplets_json_path} || echo '${local.temp_droplets_json_path} not existing'"
    when    = "destroy"
  }

  depends_on = [
    digitalocean_kubernetes_cluster.smykla-prod
  ]
}

data "local_file" "droplets_json" {
  filename = local.temp_droplets_json_path

  depends_on = [
    null_resource.get_droplets
  ]
}

locals {
  droplet_ids = [
    for droplet in jsondecode(data.local_file.droplets_json.content).droplets :
    droplet.id
    if contains(droplet.tags, "k8s:${digitalocean_kubernetes_cluster.smykla-prod.id}")
  ]

  depends_on = [
    null_resource.get_droplets
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

resource "helm_release" "nginx-ingress" {
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
    name  = "controller.service.nodePorts.https"
    value = "32169"
  }

  timeout = 600

  depends_on = [
    kubernetes_service_account.tiller,
    kubernetes_cluster_role_binding.tiller
  ]
}

locals {
  cert-manager = {
    crds-path = "https://raw.githubusercontent.com/jetstack/cert-manager/release-0.8/deploy/manifests/00-crds.yaml"
  }
  temp_kubeconfig_path = "/tmp/kubeconfig_qwerty9876"
}

resource "null_resource" "cert-manager-crds" {
  provisioner "local-exec" {
    command = "${path.cwd}/scripts/kubectl_operations.sh --cluster-id ${digitalocean_kubernetes_cluster.smykla-prod.id} --kubeconfig-path ${local.temp_kubeconfig_path} --crds-path ${local.cert-manager.crds-path}"
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = "rm ${local.temp_kubeconfig_path} || echo '${local.temp_kubeconfig_path} not existing'"
  }

  //  depends_on = [
  //    digitalocean_kubernetes_cluster.smykla-prod
  //  ]
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
    command = "${path.cwd}/scripts/kubectl_operations.sh --cluster-id ${digitalocean_kubernetes_cluster.smykla-prod.id} --kubeconfig-path ${local.temp_kubeconfig_path} --create-cluster-issuers"
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = "rm ${local.temp_kubeconfig_path}"
  }

  depends_on = [
    helm_release.cert-manager
  ]
}

data "digitalocean_domain" "smykla-blog" {
  name = "smykla.blog"
}

resource "digitalocean_record" "wildcard-smykla-blog" {
  domain = data.digitalocean_domain.smykla-blog.name
  type   = "A"
  name   = "*"
  value  = digitalocean_loadbalancer.smykla-prod-public-lb.ip
  ttl    = 60
}

resource "kubernetes_deployment" "simple-go-server" {
  metadata {
    name = "simple-go-server"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "simple-go-server"
      }
    }
    template {
      metadata {
        name = "simple-go-server"
        labels = {
          app = "simple-go-server"
        }
      }
      spec {
        container {
          name  = "simple-go-server"
          image = "bartsmykla/simple-go-http-server:0.0.3"
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "simple-go-server" {
  metadata {
    name = "simple-go-server"
    labels = {
      app = "simple-go-server"
    }
  }

  spec {
    selector = {
      app = "simple-go-server"
    }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_ingress" "simple-go-server-ingress" {
  metadata {
    name = "simple-go-server-ingress"
    annotations = {
      "ingress.kubernetes.io/ssl-redirect"     = "true"
      "kubernetes.io/tls-acme"                 = "true"
      "certmanager.k8s.io/cluster-issuer"      = "letsencrypt-staging"
      "kubernetes.io/ingress.class"            = "nginx"
      "certmanager.k8s.io/acme-challenge-type" = "dns01"
      "certmanager.k8s.io/acme-dns01-provider" = "prod-digitalocean"
    }
  }

  spec {
    tls {
      hosts       = ["demo.smykla.blog"]
      secret_name = "demo-smykla-blog-tls-cert"
    }
    rule {
      host = "demo.smykla.blog"
      http {
        path {
          path = "/"
          backend {
            service_name = "simple-go-server"
            service_port = 8080
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.cert-manager,
    null_resource.cluster-issuer
  ]
}