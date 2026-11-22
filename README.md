# 👋 Bonjour

## Simple UART implementation for Lattice iCE40🧊 FPGAs.

**Bonjour** is a lightweight UART (Universal Asynchronous Receiver/Transmitter) implementation written in Verilog, designed for FPGA projects based on the **Lattice iCE40** family.

## 📁 Project Structure

```text
Bonjour/
├── uart_tx.v          # UART transmitter
├── uart_rx.v          # UART receiver
├── bonjour.pcf        # iCE40 pin constraints
├── tb_uart_tx.v       # UART transmitter testbench
└── .gitignore
```

## 🧪 Simulation

```bash
$ iverilog -g2012 -o tb_uart_tx.sim tb_uart_tx.v uart_tx.v
$ vvp tb_uart_tx.sim
```

## 🧊 Target

```bash
$ picocom -b 115200 /dev/ttyUSB1
picocom v3.1

port is        : /dev/ttyUSB1
flowcontrol    : none
baudrate is    : 115200
parity is      : none
databits are   : 8
stopbits are   : 1
escape is      : C-a
local echo is  : no
noinit is      : no
noreset is     : no
hangup is      : no
nolock is      : no
send_cmd is    : sz -vv
receive_cmd is : rz -vv -E
imap is        : 
omap is        : 
emap is        : crcrlf,delbs,
logfile is     : none
initstring     : none
exit_after is  : not set
exit is        : no

Type [C-a] [C-h] to see available commands
Terminal ready
help
Commands:
  help
  bonjour
  led on/off
  led N on/off
  status
  version

> bonjour
Bonjour!
Welcome to Bonjour FPGA.
Type 'help' for commands.

> status
FPGA: iCE40HX1K
Clock: 12 MHz
UART: 115200
> version
Bonjour FPGA v1.4
> led on
LEDs ON
> 
Terminating...
Thanks for using picocom
```

## 👨‍💻 Author
**Pierre GENARD**
