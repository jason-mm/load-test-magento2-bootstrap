#!/bin/bash

dir=$(pwd -P)
path=$(basename $dir)
database=$1
MYSQLUSER=$2
MYSQLPASSWORD=$3
domain=$4
version=$5
databaseVersion=$6

function usage()
{
    echo "Usage: ./setup.sh database-name database-username database-password domain-name [magento-version] [database-variation]";
    echo "  database-name       Name of the database which to use for installment";
    echo "  database-username   Username which is assigned to database";
    echo "  database-password   Password for database username";
    echo "  domain-name         Domain name of the test system";
    echo "  magento-version     Magento version to install, by default: latest";
    echo "  database-variation  Special variation of database to install: original, large";
    exit 1
}

if [[ $database == "" ]]
then
    echo "Please provide a database name as a first argument"
    usage
fi

if [[ $domain == "" ]]
then
    echo "Please provide a domain name as a second argument"
    usage
fi


if [[ $version == "" ]]
then
    version="latest"
fi

if [[ $databaseVersion == "" ]]
then
    databaseVersion=""
fi

dbfile=$dir/db/data.sql.gz

if [ -f $dir/db/data-$databaseVersion-$version.sql.gz ]
then
   dbfile=$dir/db/data-$databaseVersion-$version.sql.gz
elif [ -f $dir/db/data-$version.sql.gz ]
then
   dbfile=$dir/db/data-$version.sql.gz
elif [ -f $dir/db/data-$databaseVersion.sql.gz ]
then
   dbfile=$dir/db/data-$databaseVersion.sql.gz
fi

baseDbFile=$(basename $dbfile)

# Install magento configure it
mkdir $dir/magento
cd $dir/magento

wget -c https://magento.mirror.hypernode.com/releases/magento-$version.tar.gz &&
tar -xvf magento-$version.tar.gz &&
chmod a+rwx bin/magento &&

function cache_magento() {
   cache_path=$HOME/cache/$path-$version
   mkdir -p $cache_path
   mysqldump $database | gzip -c > $cache_path/$baseDbFile
}

function try_restore_from_cache() {
   cache_path=$HOME/cache/$path-$version
   if [ ! -d $HOME/cache ]
   then
      setup_magento
   elif [ -f $cache_path/$baseDbFile ]
   then
      mysql -e "drop database if exists $database; create database $database;"
      gunzip < $cache_path/$baseDbFile | mysql $database
      php70 bin/magento setup:install --db-host="localhost" --db-name="$database" --db-user="$MYSQLUSER" \
       --db-password="$MYSQLPASSWORD" --admin-firstname=Admin --admin-lastname=User \
       --admin-user=admin --admin-password=Password123 --admin-email=test@example.com \
       --base-url="http://$domain/" --language=en_US --timezone=Europe/Amsterdam \
       --currency=USD --use-rewrites=1

      if [[ $NO_REDIS == "" ]]
      then
         # Enable redis cache in Magento 2
         LOCAL_XML=$dir/magento/app/etc/env.php php $dir/config/configure-redis.php
      fi

      php70 bin/magento cache:flush
      php70 bin/magento cache:enable
   else
      setup_magento
      cache_magento
   fi
}

function setup_magento() {
    echo "Importing $dbfile"
    mysql -e "drop database if exists $database; create database $database;"
    gunzip < $dbfile | mysql $database

    fixFile=$dir/db/data-fix-$version.sql

    if [ -f $fixFile ]
    then
       echo "Fixing setup_module table for $version, as structure didn't change but module setup version did"
       mysql $database < $fixFile
    fi

    php70 bin/magento setup:install --db-host="localhost" --db-name="$database" --db-user="$MYSQLUSER" \
      --db-password="$MYSQLPASSWORD" --admin-firstname=Admin --admin-lastname=User \
      --admin-user=admin --admin-password=Password123 --admin-email=test@example.com \
      --base-url="http://$domain/" --language=en_US --timezone=Europe/Amsterdam \
      --currency=USD --use-rewrites=1

   # Enable redis cache in Magento 2
   if [[ $NO_REDIS == "" ]]
   then
      LOCAL_XML=$dir/magento/app/etc/env.php php $dir/config/configure-redis.php
   fi

   n98-magerun2 config:set web/unsecure/base_url http://$domain/
   n98-magerun2 config:set web/secure/base_url http://$domain/
   n98-magerun2 config:set catalog/frontend/flat_catalog_category 1
   n98-magerun2 config:set catalog/frontend/flat_catalog_product 1
   # Make same category product per page positions as in Magento 1.0
   n98-magerun2 config:set catalog/frontend/grid_per_page_values "12,24,36"
   n98-magerun2 config:set catalog/frontend/grid_per_page "12"
   n98-magerun2 config:set system/full_page_cache/caching_application 2
   n98-magerun2 config:set system/full_page_cache/ttl 86400
   n98-magerun2 config:set dev/grid/async_indexing 1
   n98-magerun2 config:set sales_email/general/async_sending 1

   php70 bin/magento cache:flush
   php70 bin/magento indexer:reindex cataloginventory_stock
   php70 bin/magento indexer:reindex
   php70 bin/magento cache:enable
}

try_restore_from_cache

php70 bin/magento deploy:mode:set production
php70 bin/magento cache:flush

$dir/optimize-composer.sh

cd $dir

[ ! -d ../public ] || rm ../public/*.txt
[ ! -d ../public ] || rmdir ../public

if [[ $NO_VARNISH == "" ]]
then
   varnishadm vcl.load m2benchmark $dir/config/varnish.vcl
   varnishadm vcl.use m2benchmark
fi


if [[ $NO_IMAGES == "" ]]
then
    bash $dir/config/media.sh $dir/magento/pub $dir/config/media.set $dir/config/media
fi

ln -fsn $path/magento/pub ../public
