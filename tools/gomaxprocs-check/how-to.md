1. `make build`
2. Copy binary to the pod that is running a process you want to check its GOMAXPROC config. i.e: `oc cp /tmp/gomaxprocs-check  openshift-apiserver/apiserver-78d4f57fdd-5x55l:/tmp/gomaxprocs-check`
3. Connect to the pod: `oc -n openshift-apiserver rsh apiserver-78d4f57fdd-5x55l`
4. Run the tool (should match the number of reserved cpus):

    ~~~sh
    sh-5.1# /tmp/gomaxprocs-check
    GOMAXPROCS:      4
    NumCPU:          4
    GOMAXPROCS env:  <not set>
    ~~~
