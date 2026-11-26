# cloud-00 hypotheses (smoke test of the cloud lab environment)

1. tools/cloud_images.sh loaded nginx-devops/nginx:1.31.10 onto the kind nodes, so a pod
   with that image starts without pulling; `nginx -v` in it reports 1.31.10 and `nginx -V`
   lists --with-control-api (labs/cloud-images/nginx/Dockerfile).
2. The image keeps the official image's process layout: nginx runs in the foreground as
   PID 1 (`daemon off`), the master as root, workers as the nginx user, and the
   STOPSIGNAL is SIGQUIT.
3. A request from another pod through the Service name reaches the pod, and $hostname in
   the response is the pod name.
4. Deleting the namespace on exit removes everything the lab created.
