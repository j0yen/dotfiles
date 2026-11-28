# loopback listener for the carbon-alive tests (CARBON_ALIVE_REF target that is open): prints its port, accepts forever.
# usage: python3 -I carbon-alive-listen.py > portfile &
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
while True:
    s.accept()[0].close()
