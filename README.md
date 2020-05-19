# K8s RBAC Management Tools

Just a collection of tools that I use for managing RBAC on Kubernetes. This will
no doubt be an ongoing and evolving project.

## Cloning Repo

Because submodules are heavily used here, make sure to clone this repo by:

```bash
git clone https://github.com/mrlesmithjr/k8s-rbac-management-tools.git --recursive
```

## Utils

In the [utils](utils/) directory you will find a collection of useful Git
submodules. You will most definitely want to keep them up to date.

Updating submodules:

```bash
git submodule update --remote --init --recursive
```

## Creating Users

```bash
sh create_kube_users.sh -a apply -d ../KUBE_CONFIGS -k /Users/larrysmithjr/.kube/config -o TEST -t private_key_template.json -u "$(whoami)"
```

## Configuration Directory

File structure is based on `$USERNAME` which is derived from `-u` and `$KUBE_CLUSTER_NAME`.
The `$KUBE_CLUSTER_NAME` represents `docker-desktop` in the example below. So,
if you had multiple clusters defined in your `KUBECONFIG` derived from `-k`. You
would have multiple files based on each cluster. Whereas the users generated
`KUBECONFIG` is simply `config`.

```bash
tree KUBE_CONFIGS
KUBE_CONFIGS
└── larrysmithjr
    ├── config
    ├── docker-desktop-ca.pem
    ├── larrysmithjr-docker-desktop-key.pem
    ├── larrysmithjr-docker-desktop-rbac-access.yaml
    ├── larrysmithjr-docker-desktop.csr
    └── larrysmithjr-docker-desktop.pem
```

## RBAC Manager

I am heavily leveraging [rbac-manager](https://github.com/FairwindsOps/rbac-manager)
to handle all bindings, etc.

You can apply the `rbac-manager` manifest using one of the following:

```bash
   kubectl apply -f https://raw.githubusercontent.com/FairwindsOps/rbac-manager/master/deploy/all.yaml
```

```bash
   kubectl apply -f utils/rbac-manager/deploy/all.yaml
```

## License

MIT

## Author Information

Larry Smith Jr.

- [@mrlesmithjr](https://www.twitter.com/mrlesmithjr)
- [EverythingShouldBeVirtual](http://everythingshouldbevirtual.com)
- [mrlesmithjr@gmail.com](mailto:mrlesmithjr@gmail.com)
