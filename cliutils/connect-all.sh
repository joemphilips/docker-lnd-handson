
conn=`./docker-lncli1.sh getinfo | jq ".uris[0]"`
./docker-lncli2.sh connect $conn

