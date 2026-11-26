# Not pinned yet. Images are per region, so the template ships no image of its own (an image of somebody else's region would not exist
# in yours). With the line empty, an apply takes the newest image Oracle offers for the cluster's Kubernetes version; `tofu plan`
# prints the warning check "node_image_pinned". To freeze the image: after the cluster exists run the node-image workflow once
# (Actions -> node-image -> Run workflow): it opens a pull request that writes "<source name>|<image OCID>" into this line and
# changes nothing in the cluster. Merge it. Changing this line later replaces the worker nodes one at a time: read docs/NODE-IMAGE.md.
node_image = ""
