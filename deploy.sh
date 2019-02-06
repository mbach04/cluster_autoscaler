#!/bin/bash

#https://docs.openshift.com/container-platform/3.11/admin_guide/cluster-autoscaler.html
#https://github.com/openshift/cluster-autoscaler-operator
#https://github.com/kubernetes/autoscaler

#Create a new Ansible inventory file on your local host:
cat <<EOF > temp_hosts
[OSEv3:children]
masters
nodes
etcd

[OSEv3:vars]
openshift_deployment_type=openshift-enterprise
ansible_ssh_user=ec2-user
openshift_clusterid=mycluster
ansible_become=yes

[masters]
[etcd]
[nodes]
EOF

#Create provisioning file, build-ami-provisioning-vars.yaml
cat <<EOF > build-ami-provisioning-vars.yaml
openshift_deployment_type: openshift-enterprise
openshift_aws_clusterid: mycluster 
openshift_aws_region: us-east-1 
openshift_aws_create_vpc: false 
openshift_aws_vpc_name: production 
openshift_aws_subnet_az: us-east-1d 
openshift_aws_create_security_groups: false 
openshift_aws_ssh_key_name: production-ssh-key 
openshift_aws_base_ami: ami-12345678 
openshift_aws_create_s3: False 
openshift_aws_build_ami_group: default 
openshift_aws_vpc: 
  name: "{{ openshift_aws_vpc_name }}"
  cidr: 172.18.0.0/16
  subnets:
    us-east-1:
    - cidr: 172.18.0.0/20
      az: "us-east-1d"
container_runtime_docker_storage_type: overlay2 
container_runtime_docker_storage_setup_device: /dev/xvdb 

# atomic-openshift-node service requires gquota to be set on the
# filesystem that hosts /var/lib/origin/openshift.local.volumes (OCP
# emptydir). Often is it not ideal or cost effective to deploy a vol
# for emptydir. This pushes emptydir up to the / filesystem. Base ami
# often does not ship with gquota enabled for /. Set this bool true to
# enable gquota on / filesystem when using Red Hat Cloud Access RHEL7
# AMI or Amazon Market RHEL7 AMI.
openshift_aws_ami_build_set_gquota_on_slashfs: true 

rhsub_user: user@example.com 
rhsub_pass: password 
rhsub_pool: pool-id
EOF

#Generate the primed image
ansible-playbook -i $OCP_ANSIBLE_FILE_PATH \
    /usr/share/ansible/openshift-ansible/playbooks/aws/openshift-cluster/build_ami.yml \
    -e @build-ami-provisioning-vars.yaml

#Create the bootstrap.kubeconfig file by copying it from the master node
ansible -i $OCP_ANSIBLE_FILE_PATH \
    masters[0] -m fetch -a "src=/etc/origin/master/bootstrap.kubeconfig dest=/opt/ocp/ flat=yes"

#Create the user-data.txt cloud-init file from the bootstrap.kubeconfig file:
cat <<EOF > user-data.txt
#cloud-config
write_files:
- path: /root/openshift_bootstrap/openshift_settings.yaml
  owner: 'root:root'
  permissions: '0640'
  content: |
    openshift_node_config_name: node-config-compute
- path: /etc/origin/node/bootstrap.kubeconfig
  owner: 'root:root'
  permissions: '0640'
  encoding: b64
  content: |
    $(base64 ~/bootstrap.kubeconfig | sed '2,$s/^/    /')

runcmd:
- [ ansible-playbook, /root/openshift_bootstrap/bootstrap.yml]
- [ systemctl, restart, systemd-hostnamed]
- [ systemctl, restart, NetworkManager]
- [ systemctl, enable, atomic-openshift-node]
- [ systemctl, start, atomic-openshift-node]
EOF

#Create the Launch Configuration by using the AWS CLI
aws autoscaling create-launch-configuration \
    --launch-configuration-name mycluster-LC \ 
    --region us-east-1 \ 
    --image-id ami-987654321 \ 
    --instance-type m4.large \ 
    --security-groups sg-12345678 \ 
    --user-data file://user-data.txt \ 
    --key-name production-key

#Create the Auto Scaling group by using the AWS CLI
aws autoscaling create-auto-scaling-group \
      --auto-scaling-group-name mycluster-ASG \ 
      --launch-configuration-name mycluster-LC \ 
      --min-size 0 \ 
      --max-size 6 \ 
      --vpc-zone-identifier subnet-12345678 \ 
      --tags ResourceId=mycluster-ASG,ResourceType=auto-scaling-group,Key=Name,Value=mycluster-ASG-node,PropagateAtLaunch=true ResourceId=mycluster-ASG,ResourceType=auto-scaling-group,Key=kubernetes.io/cluster/mycluster,Value=true,PropagateAtLaunch=true ResourceId=mycluster-ASG,ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/node-template/label/node-role.kubernetes.io/compute,Value=true,PropagateAtLaunch=true

#Add the following parameter to the inventory file that you used to create the cluster
echo "openshift_master_bootstrap_auto_approve=true" >> $OCP_ANSIBLE_FILE_PATH

#To obtain the auto-scaler components, run the playbook again
ansible-playbook -i $OCP_ANSIBLE_FILE_PATH \
    /usr/share/ansible/playbooks/deploy_cluster.yml

#Confirm that the bootstrap-autoapprover pod is running
oc get pods --all-namespaces | grep bootstrap-autoapprover

#Create a namespace for the autoscaler
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cluster-autoscaler
  annotations:
    openshift.io/node-selector: ""
EOF

#Create a serviceaccount for the autoscaler
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-addon: cluster-autoscaler.addons.k8s.io
    k8s-app: cluster-autoscaler
  name: cluster-autoscaler
  namespace: cluster-autoscaler
EOF

#Create a cluster role to grant the required permissions to the service account
oc apply -n cluster-autoscaler -f - <<EOF
apiVersion: v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler
rules:
- apiGroups:
  - ""
  resources:
  - persistentvolumeclaims
  - persistentvolumes
  - pods
  - replicationcontrollers
  - services
  verbs:
  - get
  - list
  - watch
  attributeRestrictions: null
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - get
  - list
  - watch
  - patch
  - create
  attributeRestrictions: null
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
  - patch
  - update
  attributeRestrictions: null
- apiGroups:
  - extensions
  - apps
  resources:
  - daemonsets
  - replicasets
  - statefulsets
  verbs:
  - get
  - list
  - watch
  attributeRestrictions: null
- apiGroups:
  - policy
  resources:
  - poddisruptionbudgets
  verbs:
  - get
  - list
  - watch
  attributeRestrictions: null
EOF

#Create a role for the deployment auto-scaler
oc apply -n cluster-autoscaler -f - <<EOF
apiVersion: v1
kind: Role
metadata:
  name: cluster-autoscaler
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  resourceNames:
  - cluster-autoscaler
  - cluster-autoscaler-status
  verbs:
  - create
  - get
  - patch
  - update
  attributeRestrictions: null
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - create
  attributeRestrictions: null
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  attributeRestrictions: null
EOF

#Create a creds file to store AWS credentials for the auto-scaler:
cat <<EOF > creds
[default]
aws_access_key_id = your-aws-access-key-id
aws_secret_access_key = your-aws-secret-access-key
EOF

#Create the a secret that contains the AWS credentials
oc create secret -n cluster-autoscaler generic autoscaler-credentials --from-file=creds

#Create and grant cluster-reader role to the cluster-autoscaler service account previously created
oc adm policy add-cluster-role-to-user cluster-autoscaler \
    system:serviceaccount:cluster-autoscaler:cluster-autoscaler -n cluster-autoscaler
oc adm policy add-role-to-user cluster-autoscaler \
    system:serviceaccount:cluster-autoscaler:cluster-autoscaler \
    --role-namespace cluster-autoscaler -n cluster-autoscaler
oc adm policy add-cluster-role-to-user cluster-reader \
    system:serviceaccount:cluster-autoscaler:cluster-autoscaler -n cluster-autoscaler

#Deploy the cluster autoscaler
oc apply -n cluster-autoscaler -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: cluster-autoscaler
  name: cluster-autoscaler
  namespace: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-autoscaler
      role: infra
  template:
    metadata:
      labels:
        app: cluster-autoscaler
        role: infra
    spec:
      containers:
      - args:
        - /bin/cluster-autoscaler
        - --alsologtostderr
        - --v=4
        - --skip-nodes-with-local-storage=False
        - --leader-elect-resource-lock=configmaps
        - --namespace=cluster-autoscaler
        - --cloud-provider=aws
        - --nodes=0:6:mycluster-ASG
        env:
        - name: AWS_REGION
          value: us-east-1
        - name: AWS_SHARED_CREDENTIALS_FILE
          value: /var/run/secrets/aws-creds/creds
        image: registry.redhat.io/openshift3/ose-cluster-autoscaler:v3.11.0
        name: autoscaler
        volumeMounts:
        - mountPath: /var/run/secrets/aws-creds
          name: aws-creds
          readOnly: true
      dnsPolicy: ClusterFirst
      nodeSelector:
        node-role.kubernetes.io/infra: "true"
      serviceAccountName: cluster-autoscaler
      terminationGracePeriodSeconds: 30
      volumes:
      - name: aws-creds
        secret:
          defaultMode: 420
          secretName: autoscaler-credentials
EOF

