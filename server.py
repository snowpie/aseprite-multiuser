import sys
import socket
import os
import threading
import time

if len(sys.argv) < 3:
    print("usage: server.py <port> <peer_ip>")
    sys.exit(1)

PORT = int(sys.argv[1])
PEER_IP = sys.argv[2]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
COMMAND_FILE = os.path.join(SCRIPT_DIR, "command.txt")

print(f"Plugin folder: {SCRIPT_DIR}")
print(f"Command file: {COMMAND_FILE}")

running = True

def save_cel(filename):
    out_name = filename.replace("cel_", "celIn_", 1)
    OUT_ASE = os.path.join(SCRIPT_DIR, out_name)
    with open(OUT_ASE, "wb") as f:
        f.write(chunks)
    print(f"Received {filename} from {addr}")

def save_position(data):
    try:
        text = data.decode("utf-8")
        parts = text.split("|")
        if len(parts) != 2:
            print(f"Invalid position format: {text}")
            return
        layer_name, frame_num = parts
        pos_file = os.path.join(SCRIPT_DIR, "position.txt")
        with open(pos_file, "w") as f:
            f.write(f"{text}")
        print(f"Saved position: {layer_name} frame {frame_num}")
    except Exception as e:
        print(f"Position save error: {e}")


def send_cel(filepath):
    try:
        if not os.path.isfile(filepath):
            print(f"File not found: {filepath}")
            return

        with open(filepath, "rb") as f:
            data = f.read()
            
        filename = filepath.split("/")[-1]

        header = f"{filename}".encode("utf-8")

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect((PEER_IP, PORT))
        s.sendall(header + data)
        s.close()

        print(f"Sent cel {filename} ({len(data)} bytes)")

    except Exception as e:
        print(f"Send error: {e}")

def send_position(position):
    try:
        header = f"{position}".encode("utf-8")

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect((PEER_IP, PORT))
        s.sendall(header)
        s.close()

        print(f"Sent position {position} ({len(header)} bytes)")

    except Exception as e:
        print(f"Send error: {e}")
        
def receive_data(conn):
    header = b""
    while True:
        b = conn.recv(1)
        if not b:
            break
        header += b
        if header.endswith(b".ase"):
            break
    name = header.decode("utf-8")

    data = bytearray()
    while chunk := conn.recv(4096):
        if not chunk:
            break
        data.extend(chunk)

    if name.endswith(".ase"):
        return "CEL", name, data
    else:
        return "POSITION", name, data



def command_listener():
    global running

    while running:
        try:
            if os.path.exists(COMMAND_FILE):
                with open(COMMAND_FILE, "r") as f:
                    lines = f.readlines()

                os.remove(COMMAND_FILE)

                for line in lines:
                    command = line.strip()
                    if not command:
                        continue

                    if command.startswith("SENDCEL:"):
                        meta = command[len("SENDCEL:"):]
                        print(f"Command SENDCEL {meta}")
                        send_cel(meta)

                    elif command.startswith("POSITION:"):
                        meta = command[len("POSITION:"):]
                        print(f"Command POSITION {meta}")
                        send_position(meta)

                    elif command == "SHUTDOWN":
                        print("Shutdown command received")
                        running = False
                        return

        except Exception as e:
            print(f"Command error: {e}")

        time.sleep(0.005)


threading.Thread(target=command_listener, daemon=True).start()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("0.0.0.0", PORT))
s.listen(1)
s.settimeout(1)

print(f"P2P server listening on port {PORT}, peer {PEER_IP}")

while running:
    try:
        conn, addr = s.accept()

        data_type, name, chunks = receive_data(conn)
        conn.close()

        if data_type == "CEL":
            save_cel(name)
        elif data_type == "POSITION":
            save_position(name.encode("utf-8"))

    except socket.timeout:
        continue
    except Exception as e:
        if running:
            print(f"Server error: {e}")


s.close()
print("Server closed")