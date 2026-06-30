# 🚀 Guide de Démarrage Rapide - RustDesk Web Client

> **BVDKH production:** bỏ qua hướng dẫn generic bên dưới và dùng `deploy_offline.ps1` theo `DEPLOYMENT_BVDKH.md`. Production không publish trực tiếp các port WebSocket.

## 📋 Versions utilisées
- **Flutter**: 3.22.1
- **Tag**: fix-build (par défaut)
- **Repository**: MonsieurBiche/rustdesk-web-client
- **Support WSS**: Activé

## Démarrage en 3 étapes

### 1. Build et démarrage automatique
```bash
cd /home/pmietlicki/rustdesk
./build.sh build
```

### 2. Accès à l'application
- **Interface Web**: http://localhost:5000
- **WebSocket**: ws://localhost:21117

### 3. Vérification
```bash
# Statut du conteneur
docker ps | grep rustdesk

# Logs en temps réel
docker logs -f rustdesk-web
```

## 🔧 Options alternatives

### Docker Compose
```bash
docker-compose up --build -d
```

### Build manuel
```bash
docker build -t rustdesk-web-client .
docker run -d -p 5000:80 -p 21117:21117 --name rustdesk-web rustdesk-web-client
```

## ⚙️ Configuration avancée

### Variables d'environnement
```bash
# Personnaliser le tag
export RUSTDESK_TAG=enable-wss

# Changer le repository source
export RUSTDESK_REPO=MonsieurBiche/rustdesk-web-client

# Activer WSS
export ENABLE_WSS=true
```

### Voir config-examples.env pour plus d'options

## 📊 Commandes utiles

```bash
# Menu interactif
./build.sh

# Commandes directes
./build.sh start    # Démarrer
./build.sh stop     # Arrêter
./build.sh logs     # Voir les logs
./build.sh status   # Statut
./build.sh clean    # Nettoyage
```

## 🔍 Diagnostic avancé

### Vérifier la configuration
```bash
# Variables d'environnement actives
./build.sh config

# Statut détaillé
./build.sh status --verbose

# Logs par service
docker logs rustdesk-web-client | grep -E "(ERROR|WARNING)"
```

### Build échoue
```bash
# Nettoyage complet
./build.sh clean --all

# Rebuild avec logs détaillés
./build.sh build --verbose
```

### Page blanche
```bash
docker exec rustdesk-web-client ls -la /app/build/web/
```

### Port occupé
```bash
# Changer les ports dans docker-compose.yml
ports:
  - "8080:5000"  # Web
  - "8117:21117" # WebSocket
```

## ✅ Vérifications de santé

- ✅ **Service Web**: `curl http://localhost:5000`
- ✅ **Conteneur**: `docker ps | grep healthy`
- ✅ **Logs**: `docker logs rustdesk-web-client | tail -20`

## 🔒 Configuration SSL/TLS (Production)

### Activation WSS
```bash
# Dans docker-compose.yml, décommenter la section SSL
# Puis configurer vos certificats dans ./ssl/
```

### Ports sécurisés
- **HTTPS**: 443
- **WSS**: 21118

## 🎯 Prochaines étapes

1. **Test de connexion** avec un client RustDesk
2. **Configuration SSL** pour la production
3. **Personnalisation** des paramètres

Pour plus de détails, consultez le [README.md](README.md) complet.
