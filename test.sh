#!/bin/bash

#https://docs.openshift.com/container-platform/3.11/admin_guide/cluster-autoscaler.html#testing-AWS-cluster-auto-scaler_cluster-auto-scaler

#Create the scale-up.yaml file that contains the deployment configuration to test auto-scaling
cat <<EOF > scale-up.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-up
  labels:
    app: scale-up
spec:
  replicas: 20 
  selector:
    matchLabels:
      app: scale-up
  template:
    metadata:
      labels:
        app: scale-up
    spec:
      containers:
      - name: origin-base
        image: openshift/origin-base
        resources:
          requests:
            memory: 2Gi
        command:
        - /bin/sh
        - "-c"
        - "echo 'this should be in the logs' && sleep 86400"
      terminationGracePeriodSeconds: 0
EOF

#Create a namespace for the deployment
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: autoscaler-demo
EOF

#Deploy the configuration
oc apply -n autoscaler-demo -f scale-up.yaml

#View the pods in the new namespace
oc get pods -n autoscaler-demo | grep Running

#View the pending pods in your namespace
oc get pods -n autoscaler-demo | grep Pending

#Allow time for the new node to create and join the cluster
sleep 240

#After several minutes, check the list of nodes to see if new nodes are ready
oc get nodes

#When more nodes are ready, view the running pods in your namespace again
oc get pods -n autoscaler-demo

