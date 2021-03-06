#!/bin/sh

# shellcheck source=./default.conf
. "./default.conf"

# builds and installs one package for stage 3

if test "$(id -u)" = 0; then
	sudo -u cross "$0" "$1"
	exit 0
fi

PACKAGE=$1

# draw in default values for build variables

. "$SCRIPT_DIR/$TARGET_CPU-stage4/template/DESCR"

if test "$(find "$STAGE4_PACKAGES" -regex ".*/$PACKAGE-.*pkg\\.tar\\.xz" | wc -l)" = 0; then
	echo "Building package $PACKAGE."

	cd $STAGE4_BUILD || exit 1
	
	# clean up old build
	
	sudo rm -rf "$PACKAGE"
	rm -f "$STAGE4_PACKAGES/$PACKAGE"-*pkg.tar.xz
	ssh -i $CROSS_HOME/.ssh/id_rsa root@$STAGE1_MACHINE_IP rm -rf "/build/$PACKAGE"

	# check out the package build information from the upstream git rep
	# using asp (or from the AUR using yaourt)
	
	PACKAGE_DIR="$SCRIPT_DIR/$TARGET_CPU-stage4/$PACKAGE"
	PACKAGE_CONF="$PACKAGE_DIR/DESCR"	
	if test -f "$PACKAGE_CONF"; then
		if test "$(grep -c FETCH_METHOD "$PACKAGE_CONF")" = 1; then
			FETCH_METHOD=$(grep FETCH_METHOD "$PACKAGE_CONF" | cut -f 2 -d = | tr -d '"')
		fi
	fi
	case $FETCH_METHOD in
		"asp")
			$ASP export "$PACKAGE"
			;;
		"yaourt")
			yaourt -G "$PACKAGE"
			;;
		"packages32")
			if test -d "$ARCHLINUX32_PACKAGES/extra/$PACKAGE"; then
				cp -a "$ARCHLINUX32_PACKAGES/extra/$PACKAGE" .
			fi
			if test -d "$ARCHLINUX32_PACKAGES/core/$PACKAGE"; then
				cp -a "$ARCHLINUX32_PACKAGES/core/$PACKAGE" .
			fi
			;;
		*)
			echo "ERROR: unknown FETCH_METHOD '$FETCH_METHOD'.." >&2
			exit 1
	esac
			
	cd "$PACKAGE" || exit 1

	# attach our destination platform to be a supported architecture
	sed -i "/^arch=[^#]*any/!{/^arch=(/s/(/($TARGET_CPU /}" PKGBUILD

	# if there is a packages32 diff-PKGBUILD, attach it at the end
	# (we assume, we build only 'core' packages during stage1)
	for repo in core extra community; do
		DIFF_PKGBUILD="$ARCHLINUX32_PACKAGES/$repo/$PACKAGE/PKGBUILD"
		if test -f "$DIFF_PKGBUILD"; then
			cat "$DIFF_PKGBUILD" >> PKGBUILD
		fi
	done

	# copy all other files from Archlinux32, if they exist
	for repo in core extra community; do
		DIFF_PKGBUILD="$ARCHLINUX32_PACKAGES/$repo/$PACKAGE/PKGBUILD"
		if test -f "$DIFF_PKGBUILD"; then
			find "$ARCHLINUX32_PACKAGES/$repo/$PACKAGE"/* ! -name PKGBUILD \
				-exec cp {} . \;
		fi
	done
		
	# source package descriptions, sets variables for this script
	# and executes whatever is needed to build the package

	if test -f "$PACKAGE_CONF"; then
		. "$PACKAGE_CONF"
	fi

	# copy all files into the build area on the target machine 
	# (but the package DESCR file)
	
	if test -d "$PACKAGE_DIR"; then
		find "$PACKAGE_DIR"/* ! -name DESCR \
			-exec cp {} . \;
	fi
	
	# execute makepkg on the host
	# we would actually like to have a mode like 'download, and noextract' but
	# makepkg is not doing that (see -e and -o options)
	
	makepkg --nobuild
	rm -rf "$STAGE4_BUILD/$PACKAGE/src"

	# copy everything to the stage 1 machine
	
	scp -i $CROSS_HOME/.ssh/id_rsa -rC "$STAGE4_BUILD/$PACKAGE" build@$STAGE1_MACHINE_IP:/build/.

	# building the actual package

	echo "Building $PACKAGE on target.."
	
	if test "$SKIP_CHECK" = "1"; then
		TESTING="--nocheck"
	else
		TESTING=""
	fi
	
	ssh -i $CROSS_HOME/.ssh/id_rsa build@$STAGE1_MACHINE_IP bash -l -c "'cd $PACKAGE && makepkg --skipchecksums --skippgpcheck $TESTING'" > $PACKAGE.log 2>&1
	RES=$?
	
	tail "$PACKAGE.log"

	if test $RES = 0; then
	
		echo "Package $PACKAGE built sucessfully, installing on target.."

		# copy to our package folder in the first stage chroot
		
		ssh -i $CROSS_HOME/.ssh/id_rsa root@$STAGE1_MACHINE_IP bash -l -c "'
			cd /build/$PACKAGE
			rm -f ./*debug*.pkg.tar.xz
			cp -v ./*.pkg.tar.xz /packages/$TARGET_CPU/.
		'"

		# redo the whole pacman cache and repo (always running into trouble
		# there, packages seem to reappear in old versions)

		ssh -i $CROSS_HOME/.ssh/id_rsa root@$STAGE1_MACHINE_IP bash -l -c "'
#			rm -rf /var/cache/pacman/pkg/*
#			rm -rf /packages/$TARGET_CPU/temp.db*
#			rm -rf /packages/$TARGET_CPU/temp.files*
#			repo-add /packages/$TARGET_CPU/temp.db.tar.gz /packages/$TARGET_CPU/*pkg.tar.xz
		'"
		
		# install onto stage 1 system via pacman

		if test "$FORCE_INSTALL" = "1"; then
			FORCE="--force"
		fi
		
		ssh -i $CROSS_HOME/.ssh/id_rsa root@$STAGE1_MACHINE_IP bash -l -c "'		
			# TODO: broken [temp] repo
			if test \"$ADDITIONAL_INSTALL_PACKAGE\" != \"\"; then
				#pacman $FORCE --noconfirm -Syy $PACKAGE $ADDITIONAL_INSTALL_PACKAGE
				pacman $FORCE --noconfirm -U /packages/$TARGET_CPU/$PACKAGE-*.pkg.tar.xz /packages/$TARGET_CPU/$ADDITIONAL_INSTALL_PACKAGE-*.pkg.tar.xz
			else
				#pacman $FORCE --noconfirm -Syy $PACKAGE
				pacman $FORCE --noconfirm -U /packages/$TARGET_CPU/$PACKAGE-*.pkg.tar.xz
			fi
		'"
		
		# copy packages from target machine and replace our local version with it

		echo "Salvaging build environment of $PACKAGE from target back to host.."

		tmp_dir=$(mktemp -d 'tmp.compute-dependencies.0.XXXXXXXXXX' --tmpdir)
		trap 'rm -rf --one-file-system "${tmp_dir}"' EXIT
		
		cd $STAGE4_BUILD || exit 1
		mv "$STAGE4_BUILD/$PACKAGE/$PACKAGE.log" "$tmp_dir"
		cd "$STAGE4_BUILD" || exit 1
		rm -rf "$PACKAGE"
		ssh -i $CROSS_HOME/.ssh/id_rsa root@$STAGE1_MACHINE_IP bash -l -c "'cd /build && tar zcf $PACKAGE.tar.gz $PACKAGE/'"		
		scp -i $CROSS_HOME/.ssh/id_rsa -rC build@$STAGE1_MACHINE_IP:/build/"$PACKAGE.tar.gz" "$STAGE4_BUILD/."
		ssh -i $CROSS_HOME/.ssh/id_rsa root@$STAGE1_MACHINE_IP bash -l -c "'cd /build && rm -f $PACKAGE.tar.gz'"		
		tar zxf "$PACKAGE.tar.gz"
		rm -f "$PACKAGE.tar.gz"
		mv "$tmp_dir/$PACKAGE.log" "$STAGE4_BUILD/$PACKAGE/."
		mv -vf "$STAGE4_BUILD/$PACKAGE/"*.pkg.tar.xz "$STAGE4_PACKAGES/."

		echo "Built package $PACKAGE."
		
	else	
		echo "ERROR building package $PACKAGE"
		exit 1
	fi

	cd $STAGE4_BUILD || exit 1

else
	echo "$PACKAGE exists."
fi
