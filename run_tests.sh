#!/usr/bin/env bash

#
# Copyright (c) 2018, Postgres Professional
#
# supported levels:
#		* standard
#		* scan-build
#		* hardcore
#		* nightmare
#

set -ux
status=0

# global exports
export PGPORT=55435
export VIRTUAL_ENV_DISABLE_PROMPT=1


set -e

CUSTOM_PG_BIN=$PWD/pg_bin
CUSTOM_PG_SRC=$PWD/postgresql

# here PG_VERSION is provided by postgres:X-alpine docker image
curl "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" -o postgresql.tar.bz2
echo "$PG_SHA256 *postgresql.tar.bz2" | sha256sum -c -

mkdir $CUSTOM_PG_SRC

tar \
	--extract \
	--file postgresql.tar.bz2 \
	--directory $CUSTOM_PG_SRC \
	--strip-components 1

PQS_DIR=$(pwd)
cd $CUSTOM_PG_SRC

# apply patches
if [ "$(printf '%s\n' "10" "$PG_VERSION" | sort -V | head -n1)" = "$PG_VERSION" ]; then
	#patch version 9.6
	patch -p1 < $PQS_DIR/patches/custom_signals_${PG_VERSION%.*}.patch
	patch -p1 < $PQS_DIR/patches/runtime_explain.patch;
elif [ "$(printf '%s\n' "11" "$PG_VERSION" | sort -V | head -n1)" = "$PG_VERSION" ]; then
	#patch version 10
	patch -p1 < $PQS_DIR/patches/custom_signals_${PG_VERSION%.*}.0.patch
	patch -p1 < $PQS_DIR/patches/runtime_explain.patch;
else
	#patch version 11 and newer
	patch -p1 < $PQS_DIR/patches/custom_signals_${PG_VERSION%.*}.0.patch
	patch -p1 < $PQS_DIR/patches/runtime_explain_${PG_VERSION%.*}.0.patch;
fi

# build and install PostgreSQL
if [ "$LEVEL" = "hardcore" ] || \
  [ "$LEVEL" = "nightmare" ]; then
	# enable Valgrind support
	sed -i.bak "s/\/* #define USE_VALGRIND *\//#define USE_VALGRIND/g" src/include/pg_config_manual.h

	# enable additional options
	./configure \
		CFLAGS='-Og -ggdb3 -fno-omit-frame-pointer' \
		--enable-cassert \
		--prefix=$CUSTOM_PG_BIN \
		--quiet
else
	./configure \
		--prefix=$CUSTOM_PG_BIN \
		--quiet
fi
time make -s -j$(nproc) && make -s install

# override default PostgreSQL instance
export PATH=$CUSTOM_PG_BIN/bin:$PATH
export LD_LIBRARY_PATH=$CUSTOM_PG_BIN/lib

# show pg_config path (just in case)
which pg_config

cd -

set +e

# show pg_config just in case
pg_config

# perform code checks if asked to
if [ "$LEVEL" = "scan-build" ] || \
   [ "$LEVEL" = "hardcore" ] || \
   [ "$LEVEL" = "nightmare" ]; then

	# perform static analyzis
	scan-build --status-bugs make USE_PGXS=1 || status=$?

	# something's wrong, exit now!
	if [ $status -ne 0 ]; then exit 1; fi

fi

# don't forget to "make clean"
make USE_PGXS=1 clean

# build and install extension (using PG_CPPFLAGS and SHLIB_LINK for gcov)
make USE_PGXS=1 PG_CPPFLAGS="-coverage" SHLIB_LINK="-coverage"
make USE_PGXS=1 install

# initialize database
initdb -D $PGDATA

# change PG's config
echo "port = $PGPORT" >> $PGDATA/postgresql.conf
cat test.conf >> $PGDATA/postgresql.conf

# restart cluster 'test'
if [ "$LEVEL" = "nightmare" ]; then
	ls $CUSTOM_PG_BIN/bin

	valgrind \
		--tool=memcheck \
		--leak-check=no \
		--time-stamp=yes \
		--track-origins=yes \
		--trace-children=yes \
		--gen-suppressions=all \
		--suppressions=$CUSTOM_PG_SRC/src/tools/valgrind.supp \
		--log-file=/tmp/valgrind-%p.log \
		pg_ctl start -l /tmp/postgres.log -w || status=$?
else
	pg_ctl start -l /tmp/postgres.log -w || status=$?
fi

# something's wrong, exit now!
if [ $status -ne 0 ]; then cat /tmp/postgres.log; exit 1; fi

# run regression tests
export PG_REGRESS_DIFF_OPTS="-w -U3" # for alpine's diff (BusyBox)
make USE_PGXS=1 installcheck || status=$?

# show diff if it exists
if [ -f regression.diffs ]; then cat regression.diffs; fi

# run python tests
set +x -e
python3 -m venv /tmp/env && source /tmp/env/bin/activate &&
pip install -r tests/requirements.txt
set -e #exit virtualenv with error code
python tests/pg_qs_test_runner.py --port $PGPORT
if [ -n $USE_TPCDS ]; then
	python tests/pg_qs_test_runner.py --port $PGPORT --tpc-ds
fi
deactivate
set -x

# show Valgrind logs if necessary
if [ "$LEVEL" = "nightmare" ]; then
	for f in $(find /tmp -name valgrind-*.log); do
		if grep -q 'Command: [^ ]*/postgres' $f && grep -q 'ERROR SUMMARY: [1-9]' $f; then
			echo "========= Contents of $f"
			cat $f
			status=1
		fi
	done
fi

# something's wrong, exit now!
if [ $status -ne 0 ]; then exit 1; fi
set +e
# generate *.gcov files
gcov *.c *.h

set +ux

# send coverage stats to Codecov
bash <(curl -s https://codecov.io/bash)
