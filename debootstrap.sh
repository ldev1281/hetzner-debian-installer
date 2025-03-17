#!/bin/bash

CONFIG_FILE="hetzner-debian-installer.conf.bash"

configure_debian_install() {
  read -p "Выберите версию Debian (stable, testing, sid) [stable]: " DEBIAN_RELEASE
  DEBIAN_RELEASE=${DEBIAN_RELEASE:-stable}

  read -p "Введите зеркало репозитория Debian [http://deb.debian.org/debian]: " DEBIAN_MIRROR
  DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}

  INSTALL_TARGET="/mnt"

  echo "Сохранение конфигурации в файл $CONFIG_FILE"

  cat <<EOF >> $CONFIG_FILE
DEBIAN_RELEASE="$DEBIAN_RELEASE"
DEBIAN_MIRROR="$DEBIAN_MIRROR"
INSTALL_TARGET="$INSTALL_TARGET"
EOF

  echo "Конфигурация сохранена."
}

run_debian_install() {
  source $CONFIG_FILE

  echo "Параметры установки Debian:"
  echo "Версия: $DEBIAN_RELEASE"
  echo "Зеркало: $DEBIAN_MIRROR"
  echo "Точка установки: $INSTALL_TARGET"

  read -p "Продолжить установку? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Операция отменена."
    exit 1
  fi

  # Проверка и размонтирование целевого раздела
  umount $INSTALL_TARGET/dev $INSTALL_TARGET/sys $INSTALL_TARGET/proc $INSTALL_TARGET >/dev/null 2>&1
  umount $INSTALL_TARGET >/dev/null 2>&1

  mkdir -p $INSTALL_TARGET

  echo "Запуск debootstrap..."
  debootstrap --arch=amd64 $DEBIAN_RELEASE $INSTALL_TARGET $DEBIAN_MIRROR

  if [ $? -eq 0 ]; then
    echo "Debian base system installed successfully in $INSTALL_TARGET."
  else
    echo "Ошибка: не удалось установить Debian."
    exit 1
  fi
}

# Пример вызова функций
#configure_debian_install
#run_debian_install