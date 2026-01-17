echo "== Removing GUI packages (purge only) =="

# HARD SAFETY: prevent installs
export APT_LISTCHANGES_FRONTEND=none
export DEBIAN_FRONTEND=noninteractive

GUI_PACKAGES=(
  lightdm
  xserver-xorg-core
  x11-common
  lxsession
  lxpanel
  openbox
  lxde*
)

apt-get -y purge "${GUI_PACKAGES[@]}" || true

echo "== Autoremoving unused packages =="

apt-get -y autoremove --purge
apt-get -y autoclean
