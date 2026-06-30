# RustDesk Web Client - Optimized Version

> **BVDKH production:** dùng [`DEPLOYMENT_BVDKH.md`](DEPLOYMENT_BVDKH.md) và `deploy_offline.ps1` riêng. Các ví dụ generic bên dưới chỉ là tài liệu upstream, không phải quy trình production.

⚠️ **IMPORTANT - Version Status** ⚠️

- ✅ **Version 1.1.10 (pmietlicki/docker-rustdesk-web-client:v1)** - **FULLY FUNCTIONAL**
- ⚠️ **Version 1.3.2 (latest)** - **LIMITATIONS**: Interface doesn't allow configuring custom-rendezvous-server or relay

**Recommendation**: Use version 1.1.10 for a complete production environment.

---

## 🚀 Version 1.1.10 - Fully Functional (Recommended)

### Features
- ✅ Complete custom server configuration support
- ✅ Relay server configuration
- ✅ Custom rendezvous server setup
- ✅ Full UI control for server settings
- ✅ Production-ready

### Quick Start with Docker

#### Basic Usage
```bash
docker run -d \
  --name rustdesk-web \
  -p 5000:5000 \
  pmietlicki/docker-rustdesk-web-client:v1
```

#### With Custom Server Configuration
```bash
docker run -d \
  --name rustdesk-web \
  -p 5000:5000 \
  -e CUSTOM_RENDEZVOUS_SERVER="your-server.com:21116" \
  -e RELAY_SERVER="your-relay-server.com:21117" \
  -e KEY="your-public-key" \
  -e API_SERVER="your-api-server.com" \
  pmietlicki/docker-rustdesk-web-client:v1
```

#### Complete Production Setup
```bash
docker run -d \
  --name rustdesk-web-prod \
  -p 443:5000 \
  -e CUSTOM_RENDEZVOUS_SERVER="prod-server.yourcompany.com:21116" \
  -e RELAY_SERVER="relay.yourcompany.com:21117" \
  -e KEY="AAAAB3NzaC1yc2EAAAADAQABAAABgQC..." \
  -e API_SERVER="api.yourcompany.com" \
  pmietlicki/docker-rustdesk-web-client:v1
```

### Environment Variables (v1.1.10)

| Variable | Description | Example |
|----------|-------------|----------|
| `CUSTOM_RENDEZVOUS_SERVER` | Your RustDesk server address:port | `my-server.com:21116` |
| `RELAY_SERVER` | Relay server address:port | `relay.example.com:21117` |
| `KEY` | Public key for encryption | `AAAAB3NzaC1yc2E...` |
| `API_SERVER` | API server address | `api.example.com` |

### Docker Compose (v1.1.10)

```yaml
version: '3.8'
services:
  rustdesk-web:
    image: pmietlicki/docker-rustdesk-web-client:v1
    container_name: rustdesk-web-v1
    ports:
      - "5000:5000"
    environment:
      - CUSTOM_RENDEZVOUS_SERVER=your-server.com:21116
      - RELAY_SERVER=your-relay.com:21117
      - KEY=your-public-key
      - API_SERVER=your-api-server.com
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000"]
      interval: 30s
      timeout: 10s
      retries: 3
```

### Docker Compose

```yaml
version: '3.8'
services:
  rustdesk-web-client:
    image: pmietlicki/docker-rustdesk-web-client:v1
    container_name: rustdesk-web-client
    ports:
      - "5000:5000"
    environment:
      - CUSTOM_RENDEZVOUS_SERVER=votre-serveur.com
      - RELAY_SERVER=votre-serveur.com
      - KEY=votre-clé-publique
      - API_SERVER=votre-api-serveur.com
    restart: unless-stopped
```

### Kubernetes

```yaml
# 1) Namespace ─────────────────────────────────────────────────────────
apiVersion: v1
kind: Namespace
metadata:
  name: rustdesk

---
# 2) PVC pour données / clés ─────────────────────────────────────────────
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustdesk-data
  namespace: rustdesk
  labels:
    app: rustdesk-server
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi

---
# 3) Deployment hbbs + hbbr (RustDesk Server OSS) ───────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustdesk-server
  namespace: rustdesk
  labels:
    app: rustdesk-server
spec:
  replicas: 1
  selector:
    matchLabels: { app: rustdesk-server }
  template:
    metadata:
      labels: { app: rustdesk-server }
    spec:
      containers:
        - name: hbbs
          image: docker.io/rustdesk/rustdesk-server:latest
          imagePullPolicy: IfNotPresent
          command: ["hbbs"]
          args: ["-k","_"]
          ports:
            - name: nat-port
              containerPort: 21115
              protocol: TCP
            - name: registry-port
              containerPort: 21116
              protocol: TCP
            - name: heartbeat-port
              containerPort: 21116
              protocol: UDP
            - name: web-port
              containerPort: 21118
              protocol: TCP
          livenessProbe:
            tcpSocket: { port: 21115 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            tcpSocket: { port: 21115 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: rustdesk-data
              mountPath: /root

        - name: hbbr
          image: docker.io/rustdesk/rustdesk-server:latest
          imagePullPolicy: IfNotPresent
          command: ["hbbr"]
          args: ["-k","_"]
          ports:
            - name: relay-port
              containerPort: 21117
              protocol: TCP
            - name: client-port
              containerPort: 21119
              protocol: TCP
          livenessProbe:
            tcpSocket: { port: 21117 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            tcpSocket: { port: 21117 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: rustdesk-data
              mountPath: /root

      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: rustdesk-server }
              topologyKey: kubernetes.io/hostname

      volumes:
        - name: rustdesk-data
          persistentVolumeClaim:
            claimName: rustdesk-data

---
# 4) Service LoadBalancer (MetalLB) ──────────────────────────────────────
apiVersion: v1
kind: Service
metadata:
  name: rustdesk-server
  namespace: rustdesk
  labels:
    app: rustdesk-server
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: { app: rustdesk-server }
  ports:
    - name: nat-port
      port: 21115
      targetPort: 21115
      protocol: TCP
    - name: registry-port
      port: 21116
      targetPort: 21116
      protocol: TCP
    - name: heartbeat-port
      port: 21116
      targetPort: 21116
      protocol: UDP
    - name: web-port
      port: 21118
      targetPort: 21118
      protocol: TCP
    - name: relay-port
      port: 21117
      targetPort: 21117
      protocol: TCP
    - name: client-port
      port: 21119
      targetPort: 21119
      protocol: TCP

---
# 5) Deployment Web Client ───────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustdesk-web-client
  namespace: rustdesk
  labels:
    app: rustdesk-web-client
spec:
  replicas: 1
  selector:
    matchLabels: { app: rustdesk-web-client }
  template:
    metadata:
      labels: { app: rustdesk-web-client }
    spec:
      containers:
        - name: web-client
          image: pmietlicki/rustdesk-web-client:v1
          imagePullPolicy: Always
          ports:
            - containerPort: 5000
          env:
            - name: CUSTOM_RENDEZVOUS_SERVER
              value: "rustdesk.test.local"
            - name: RELAY_SERVER
              value: "rustdesk.test.local"
            - name: KEY
              value: "xxxxxxxxxxxxxxxxxxxxxxx"
          livenessProbe:
            httpGet: { path: "/", port: 5000 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: "/", port: 5000 }
            initialDelaySeconds: 5
            periodSeconds: 10

---
# 6) Service ClusterIP pour Web Client ─────────────────────────────────
apiVersion: v1
kind: Service
metadata:
  name: rustdesk-web-client
  namespace: rustdesk
  labels:
    app: rustdesk-web-client
spec:
  type: ClusterIP
  selector: { app: rustdesk-web-client }
  ports:
    - port: 5000
      targetPort: 5000
      protocol: TCP
---
# 7) Ingress unique WSS + HTTPS + Web UI ────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rustdesk
  namespace: rustdesk
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
spec:
  tls:
    - hosts: [rustdesk.test.local]
      secretName: rustdesk-server-tls
  rules:
    - host: rustdesk.test.local
      http:
        paths:
          # WebSocket ID server hbbs
          - path: /ws/id
            pathType: Prefix
            backend:
              service: { name: rustdesk-server, port: { name: web-port } }
          # WebSocket relay hbbr
          - path: /ws/relay
            pathType: Prefix
            backend:
              service: { name: rustdesk-server, port: { name: client-port } }
          # Tout le reste → Web Client
          - path: /
            pathType: Prefix
            backend:
              service: { name: rustdesk-web-client, port: { number: 5000 } }
```

---

## 🔧 Version 1.3.2 - Latest (MonsieurBiche Fork)

### Features
- ✅ Latest Flutter improvements
- ✅ Enhanced performance
- ⚠️ **Limited UI configuration** for custom servers
- ⚠️ Manual configuration required

### Usage (v1.3.2)

```bash
# Basic usage - latest version
docker run -d \
  --name rustdesk-web-latest \
  -p 5000:5000 \
  pmietlicki/docker-rustdesk-web-client:latest
```

### Build from Source (v1.3.2)

```bash
# Clone and build latest version
git clone https://github.com/pmietlicki/docker-rustdesk-web-client.git
cd docker-rustdesk-web-client

# Build with MonsieurBiche improvements
export RUSTDESK_BRANCH=enable-wss
export ENABLE_WSS=true
docker-compose up --build -d
```

---

## 📋 Prerequisites

- Docker 20.10+
- Docker Compose 2.0+
- 4GB RAM minimum for build
- Stable internet connection

## 🔍 Troubleshooting

### Version 1.1.10 Issues
```bash
# Check container logs
docker logs rustdesk-web

# Verify environment variables
docker exec rustdesk-web env | grep -E "CUSTOM_RENDEZVOUS_SERVER|RELAY_SERVER|KEY|API_SERVER"

# Test connectivity
curl -f http://localhost:5000
```

### Version 1.3.2 Issues
```bash
# Check build logs
docker-compose logs rustdesk-web

# Rebuild without cache
docker-compose down
docker-compose up --build --no-cache
```

## 📚 Resources

- [RustDesk Official](https://github.com/rustdesk/rustdesk)
- [MonsieurBiche Fork](https://github.com/MonsieurBiche/rustdesk-web-client)
- [Docker Hub - v1.1.10](https://hub.docker.com/r/pmietlicki/docker-rustdesk-web-client)

---

# RustDesk Web Client - Version Optimisée (Français)

⚠️ **IMPORTANT - Statut des versions** ⚠️

- ✅ **Version 1.1.10 (pmietlicki/docker-rustdesk-web-client:v1)** - **TOTALEMENT FONCTIONNELLE**
- ⚠️ **Version 1.3.2 (latest)** - **LIMITATIONS** : Interface ne permet pas de configurer le custom-rendezvous-server ni le relay

**Recommandation** : Utilisez la version 1.1.10 pour un environnement de production complet.

---

## 🚀 Version 1.1.10 - Totalement Fonctionnelle (Recommandée)

### Fonctionnalités
- ✅ Support complet de la configuration serveur personnalisé
- ✅ Configuration du serveur relay
- ✅ Configuration du serveur rendezvous personnalisé
- ✅ Contrôle UI complet pour les paramètres serveur
- ✅ Prêt pour la production

### Démarrage Rapide avec Docker

#### Utilisation Basique
```bash
docker run -d \
  --name rustdesk-web \
  -p 5000:5000 \
  pmietlicki/docker-rustdesk-web-client:v1
```

#### Avec Configuration Serveur Personnalisé
```bash
docker run -d \
  --name rustdesk-web \
  -p 5000:5000 \
  -e CUSTOM_RENDEZVOUS_SERVER="votre-serveur.com:21116" \
  -e RELAY_SERVER="votre-relay-serveur.com:21117" \
  -e KEY="votre-clé-publique" \
  -e API_SERVER="votre-api-serveur.com" \
  pmietlicki/docker-rustdesk-web-client:v1
```

#### Configuration Production Complète
```bash
docker run -d \
  --name rustdesk-web-prod \
  -p 443:5000 \
  -e CUSTOM_RENDEZVOUS_SERVER="prod-serveur.votreentreprise.com:21116" \
  -e RELAY_SERVER="relay.votreentreprise.com:21117" \
  -e KEY="AAAAB3NzaC1yc2EAAAADAQABAAABgQC..." \
  -e API_SERVER="api.votreentreprise.com" \
  pmietlicki/docker-rustdesk-web-client:v1
```

### Variables d'Environnement (v1.1.10)

| Variable | Description | Exemple |
|----------|-------------|----------|
| `CUSTOM_RENDEZVOUS_SERVER` | Adresse:port de votre serveur RustDesk | `mon-serveur.com:21116` |
| `RELAY_SERVER` | Adresse:port du serveur relay | `relay.exemple.com:21117` |
| `KEY` | Clé publique pour le chiffrement | `AAAAB3NzaC1yc2E...` |
| `API_SERVER` | Adresse du serveur API | `api.exemple.com` |

---

## 🔧 Version 1.3.2 - Dernière (Fork MonsieurBiche)

### Fonctionnalités
- ✅ Dernières améliorations Flutter
- ✅ Performance améliorée
- ⚠️ **Configuration UI limitée** pour les serveurs personnalisés
- ⚠️ Configuration manuelle requise

### Utilisation (v1.3.2)

```bash
# Utilisation basique - dernière version
docker run -d \
  --name rustdesk-web-latest \
  -p 5000:5000 \
  pmietlicki/docker-rustdesk-web-client:latest
```

## 📄 Licence

Suit la licence du projet RustDesk original (AGPL-3.0).
