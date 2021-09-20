#!/bin/bash

docker run --rm -it --privileged -v /dev/bus/usb:/dev/bus/usb \
    -v $PWD:/home/build/ -w /home/build/ 3mdeb/fobnail-sdk
