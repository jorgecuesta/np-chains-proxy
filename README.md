### NGINX with Auto Certbot renew

This repository allow node pilot user to expose their Chains to the world to be accessed by other validators.

### How this work?

This will launch with `docker-compose` a set of 2 containers, certbot & nginx. They will be connected to the node pilot network on docker named by them: `node-manager-network`.
That allow us to be able to reach chains using their internal network names used by validators, so when you query them with that you take advantage of the internal load balance created by them for each chain.

You will look this is exposing chains over ssl but in a custom port because 443 is used by nginx that expose pokt validators by Node Pilot, so, if you dont have validators, you should be able to use normal 443

### Requirements:
- docker-compose
- edit few files
- update .env

### Hands on it

#### Update .env

Edit `.env` file with your base domain. If you want to expose your chain on: eth-mainnet.mydomain.com, so fill it with `DOMAIN=yourdomain.com`

#### Change proxy template to forward chains

You need to change `proxy/conf.d/https.conf.template` and add following block for each chain you want to expose.

I know following one (feel free to update this list with a PR):
- eth-mainnet
- fuse-mainnet
- xdai-mainnet

```nginx
# This sample is about Etherum mainnet, but is the same for all the chains,
# just need to check the internal load balancer name for the chain.

server {
     listen  4443 ssl;
     listen [::]:4443 ssl;
     resolver 127.0.0.11 ipv6=off valid=5s;

     # change eth-mainnet by the proper chain network alias on node pilot
     server_name eth-mainnet.${DOMAIN};

    # change eth-mainnet by your subdomain for this chain
     ssl_certificate /etc/nginx/ssl/live/eth-mainnet.${DOMAIN}/fullchain.pem;
     ssl_certificate_key /etc/nginx/ssl/live/eth-mainnet.${DOMAIN}/privkey.pem;

     ssl_buffer_size 8k;
     ssl_protocols TLSv1.2 TLSv1.1 TLSv1;
     ssl_prefer_server_ciphers on;
     ssl_ciphers ECDH+AESGCM:ECDH+AES256:ECDH+AES128:DH+3DES:!ADH:!AECDH:!MD5;
     ssl_ecdh_curve secp384r1;
     ssl_session_tickets off;

     # OCSP stapling
     ssl_stapling on;
     ssl_stapling_verify on;

     location / {
       proxy_ssl_verify on;
       # change to the proper node pilot chain network alias
       proxy_pass http://eth-mainnet;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection 'upgrade';
       proxy_set_header Host $host;
       proxy_cache_bypass $http_upgrade;
       proxy_http_version 1.1;
     }
}
```

#### Create Certificates for each chain.

Run:
`docker run --volume /etc/letsencrypt/:/etc/letsencrypt/  -it certbot/certbot:latest certonly --manual --agree-tos --no-eff-email --preferred-challenges=dns -d eth-mainnet.yourdomain.com`

In other terminal verify than TXT record is available:
`nslookup -type=txt _acme-challenge.eth-mainnet.yourdomain.com`

Repeat for any other chain you need

#### Startup

Recommended first time to check if any error occur

`docker-compose up` (this will handle terminal logs and you can stop all with ctrl+c)

After you test all is OK, hit ctrl + c and start it with `docker-compose up -d`

#### Test - Valid for eth, fuse, xdai and maybe any other with etherum as base (change domain)
`curl -X POST --location "https://eth-mainnet.yourdomain.com:4443" \ -H "Content-Type: application/json" \ -d "{ \"jsonrpc\":\"2.0\", \"method\":\"web3_clientVersion\", \"params\":[], \"id\":1 }`
