pkg_name=stevedore
pkg_origin=chetan
pkg_version=0.1
pkg_maintainer="Chetan Sarva <chetan@pixelcop.net>"
pkg_license=('Apache-2.0')
pkg_source=nosuchfile.tar.gz
pkg_deps=(core/coreutils core/findutils core/gawk core/grep core/bash core/docker core/hab core/hab-studio)
pkg_build_deps=()
pkg_bin_dirs=(bin)

program="stow"

do_build() {
  cp -v $PLAN_CONTEXT/bin/${program}.sh ${program}

  # Use the bash from our dependency list as the shebang. Also, embed the
  # release version of the program.
  sed \
    -e "s,#!/bin/bash$,#!$(pkg_path_for bash)/bin/bash," \
    -e "s,@author@,$pkg_maintainer,g" \
    -e "s,@version@,$pkg_version/$pkg_release,g" \
    -i $program
}

do_install() {
  install -v -D $program $pkg_prefix/bin/$program
}

# Turn the remaining default phases into no-ops

do_download() {
  return 0
}

do_verify() {
  return 0
}

do_unpack() {
  return 0
}

do_prepare() {
  return 0
}
