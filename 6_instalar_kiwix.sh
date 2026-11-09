#!/bin/bash

# =================================================================
# SCRIPT DE INSTALACIÓN DE KIWIX SERVER + WIKIPEDIA (DEBIAN)
# =================================================================

# --- VERIFICACIÓN DE USUARIO ---
if [[ $EUID -eq 0 ]]; then
   echo "🚫 ERROR: ¡No ejecute este script como root (usando 'sudo')!"
   echo "Ejecútelo como su usuario normal."
   exit 1
fi

# --- CONFIGURACIÓN DE RUTAS Y PUERTOS ---
KIWIX_DIR="$HOME/kiwix_data"
ZIM_DIR="$KIWIX_DIR/zim"
KIWIX_PORT=10000

# URL directa del archivo ZIM de Wikipedia en inglés (versión simple / mini para descarga rápida)
# Para la versión completa de Wikipedia en inglés (sin imágenes ~22GB o con imágenes ~100GB), ajusta la URL.
WIKI_ZIM_URL="https://download.kiwix.org/zim/wikipedia/wikipedia_en_simple_all_nopic_2024-01.zim"
ZIM_FILENAME="wikipedia_en_simple.zim"

echo "🚀 Iniciando la instalación de Kiwix Server..."

# ----------------------------------------------------------------
# PASO 1: INSTALAR DEPENDENCIAS Y KIWIX-TOOLS
# ----------------------------------------------------------------
instalar_kiwix_tools() {
    echo "1/4: Instalando dependencias y kiwix-tools..."
    sudo apt update -y
    sudo apt install -y curl wget kiwix-tools

    mkdir -p "$ZIM_DIR"
}

# ----------------------------------------------------------------
# PASO 2: DESCARGAR WIKIPEDIA (.ZIM)
# ----------------------------------------------------------------
descargar_wikipedia() {
    echo "2/4: Verificando archivo ZIM de Wikipedia..."
    
    if [ -f "$ZIM_DIR/$ZIM_FILENAME" ]; then
        echo "✅ El archivo $ZIM_FILENAME ya existe en $ZIM_DIR."
    else
        echo "📦 Descargando Wikipedia ($ZIM_FILENAME)..."
        wget -c "$WIKI_ZIM_URL" -O "$ZIM_DIR/$ZIM_FILENAME"
        echo "✅ Descarga completada."
    fi
}

# ----------------------------------------------------------------
# PASO 3: CONFIGURAR SERVICIO SYSTEMD PARA KIWIX
# ----------------------------------------------------------------
configurar_servicio_systemd() {
    echo "3/4: Creando servicio systemd para Kiwix Server en puerto $KIWIX_PORT..."

    SERVICE_FILE="/etc/systemd/system/kiwix.service"

    sudo bash -c "cat << EOF > $SERVICE_FILE
[Unit]
Description=Servidor Kiwix ZIM
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=/usr/bin/kiwix-serve --port=$KIWIX_PORT $ZIM_DIR/$ZIM_FILENAME
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable kiwix.service
    sudo systemctl restart kiwix.service

    echo "✅ Servicio kiwix.service activado e iniciado."
}

# ----------------------------------------------------------------
# PASO 4: VERIFICACIÓN FINAL
# ----------------------------------------------------------------
verificar_instalacion() {
    echo "4/4: Comprobando estado del servidor..."
    sleep 2

    if curl -s "http://127.0.0.1:$KIWIX_PORT" > /dev/null; then
        echo "🎉 Kiwix Server está funcionando correctamente en http://127.0.0.1:$KIWIX_PORT"
    else
        echo "⚠️ El servidor Kiwix no parece estar respondiendo en el puerto $KIWIX_PORT."
        echo "   Revisa los logs con: sudo journalctl -u kiwix.service -f"
    fi
}

# =================================================================
# EJECUCIÓN PRINCIPAL
# =================================================================
instalar_kiwix_tools
descargar_wikipedia
configurar_servicio_systemd
verificar_instalacion

echo ""
echo "=========================================================="
echo "🥳 Instalación de Kiwix completada."
echo "Puedes consultar la Wikipedia localmente desde tu navegador en:"
echo "👉 http://127.0.0.1:$KIWIX_PORT"
echo "=========================================================="

