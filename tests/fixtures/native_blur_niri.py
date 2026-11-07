#!/usr/bin/env python3
"""A private Unix-socket peer with an explicit fake niri profile."""
import argparse
import socket

parser=argparse.ArgumentParser()
parser.add_argument('--config',required=True)
parser.add_argument('--socket',required=True)
args=parser.parse_args()
server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
server.bind(args.socket); server.listen(16)
print('ready',flush=True)
while True:
    connection,_=server.accept()
    connection.close()
