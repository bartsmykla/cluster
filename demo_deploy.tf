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