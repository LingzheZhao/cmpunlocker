import mmap
import os
import struct
import subprocess
import sys
import time

NV_PJTAG_ACCESS_CTRL = 0xC800
NV_PJTAG_ACCESS_DATA = 0xC804
NV_PJTAG_ACCESS_CONFIG = 0xC808
NV_PJTAG_ACCESS_MASK = 0xC80C
NV_PJTAG_ACCESS_CONFIG2 = 0xC810
NV_PJTAG_ACCESS_PRIV_LEVEL_MASK = 0xC840
NV_PJTAG_ACCESS_SEC = 0xC844
NV_PJTAG_ACCESS_SEC_PRIV_LEVEL_MASK = 0xC848

BAR0_WINDOW = 0x1000000


def set_bits(value, hi, lo, field):
    width = hi - lo + 1
    mask = (1 << width) - 1
    return (value & ~(mask << lo)) | ((field & mask) << lo)


def get_bits(value, hi, lo):
    width = hi - lo + 1
    mask = (1 << width) - 1
    return (value >> lo) & mask


def detect_gpu_bdf():
    out = subprocess.check_output(
        ['lspci', '-d', '10de:', '-D', '-mm']
    ).decode()
    for line in out.splitlines():
        if '"3D controller"' in line or '"VGA compatible controller"' in line:
            return line.split()[0]
    raise RuntimeError('no NVIDIA GPU found via lspci')


class Bar0:
    def __init__(self, bdf):
        self.bdf = bdf
        path = f'/sys/bus/pci/devices/{bdf}/resource0'
        self.fd = os.open(path, os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, BAR0_WINDOW, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE)

    def rd(self, off):
        self.mm.seek(off)
        return struct.unpack('<I', self.mm.read(4))[0]

    def wr(self, off, val):
        self.mm.seek(off)
        self.mm.write(struct.pack('<I', val & 0xFFFFFFFF))

    def alive(self):
        return self.rd(0x0) != 0xFFFFFFFF

    def close(self):
        self.mm.close()
        os.close(self.fd)


class Host2JtagError(Exception):
    pass


def jtag_read_seq(bar, chain_len, cluster_sel, instr_id, dword_array_len, timeout=1.0):
    max_dword_en = dword_array_len
    dword_en = 0
    result = []

    bar.wr(NV_PJTAG_ACCESS_CTRL, 0)

    while dword_en < max_dword_en:
        jtag_config = 0
        jtag_config = set_bits(jtag_config, 7, 0, chain_len >> 11)
        jtag_config = set_bits(jtag_config, 15, 8, dword_en >> 6)
        jtag_config = set_bits(jtag_config, 16, 16, 1)

        jtag_ctrl = 0
        jtag_ctrl = set_bits(jtag_ctrl, 18, 8, chain_len)
        jtag_ctrl = set_bits(jtag_ctrl, 7, 0, instr_id)
        jtag_ctrl = set_bits(jtag_ctrl, 24, 19, dword_en)
        jtag_ctrl = set_bits(jtag_ctrl, 31, 31, 1)
        jtag_ctrl = set_bits(jtag_ctrl, 29, 25, cluster_sel)

        bar.wr(NV_PJTAG_ACCESS_CONFIG, jtag_config)
        bar.wr(NV_PJTAG_ACCESS_CTRL, jtag_ctrl)

        if bar.rd(NV_PJTAG_ACCESS_CTRL) == 0:
            raise Host2JtagError('no write access to host2jtag (PLM not open)')

        deadline = time.monotonic() + timeout
        while True:
            jtag_ctrl = bar.rd(NV_PJTAG_ACCESS_CTRL)
            if get_bits(jtag_ctrl, 30, 30) == 1:
                break
            if time.monotonic() > deadline:
                bar.wr(NV_PJTAG_ACCESS_CTRL, 0)
                raise Host2JtagError('timeout waiting for CTRL_STATUS')

        jtag_data = bar.rd(NV_PJTAG_ACCESS_DATA)
        if dword_en == (max_dword_en - 1) and (chain_len % 32) != 0:
            jtag_data = jtag_data >> (32 - (chain_len % 32))
        result.append(jtag_data)
        dword_en += 1

    bar.wr(NV_PJTAG_ACCESS_CTRL, 0)
    return result


def jtag_write_seq(bar, chain_len, cluster_sel, instr_id, data, timeout=1.0):
    max_dword_en = len(data)
    dword_en = 0

    bar.wr(NV_PJTAG_ACCESS_CTRL, 0)

    jtag_config = 0
    jtag_config = set_bits(jtag_config, 7, 0, chain_len >> 11)

    jtag_ctrl = 0
    jtag_ctrl = set_bits(jtag_ctrl, 18, 8, chain_len)
    jtag_ctrl = set_bits(jtag_ctrl, 7, 0, instr_id)
    jtag_ctrl = set_bits(jtag_ctrl, 31, 31, 1)
    jtag_ctrl = set_bits(jtag_ctrl, 29, 25, cluster_sel)

    bar.wr(NV_PJTAG_ACCESS_CONFIG, jtag_config)
    bar.wr(NV_PJTAG_ACCESS_CTRL, jtag_ctrl)

    if bar.rd(NV_PJTAG_ACCESS_CTRL) == 0:
        raise Host2JtagError('no write access to host2jtag (PLM not open)')

    deadline = time.monotonic() + timeout
    while True:
        jtag_ctrl = bar.rd(NV_PJTAG_ACCESS_CTRL)
        if get_bits(jtag_ctrl, 30, 30) == 1:
            break
        if time.monotonic() > deadline:
            bar.wr(NV_PJTAG_ACCESS_CTRL, 0)
            raise Host2JtagError('timeout waiting for CTRL_STATUS')

    while dword_en < max_dword_en:
        bar.wr(NV_PJTAG_ACCESS_DATA, data[dword_en])
        dword_en += 1

    bar.wr(NV_PJTAG_ACCESS_CTRL, 0)


def dump_plm_state(bar):
    names = {
        NV_PJTAG_ACCESS_CTRL: 'ACCESS_CTRL',
        NV_PJTAG_ACCESS_DATA: 'ACCESS_DATA',
        NV_PJTAG_ACCESS_CONFIG: 'ACCESS_CONFIG',
        NV_PJTAG_ACCESS_MASK: 'ACCESS_MASK',
        NV_PJTAG_ACCESS_CONFIG2: 'ACCESS_CONFIG2',
        NV_PJTAG_ACCESS_PRIV_LEVEL_MASK: 'ACCESS_PRIV_LEVEL_MASK',
        NV_PJTAG_ACCESS_SEC: 'ACCESS_SEC',
        NV_PJTAG_ACCESS_SEC_PRIV_LEVEL_MASK: 'ACCESS_SEC_PRIV_LEVEL_MASK',
    }
    for off, name in names.items():
        print(f'0x{off:05x} {name:26s} = 0x{bar.rd(off):08x}')


def main():
    bdf = detect_gpu_bdf()
    print(f'bdf={bdf}')
    bar = Bar0(bdf)
    if not bar.alive():
        print('BAR0 read as 0xFFFFFFFF, aborting')
        return 1

    dump_plm_state(bar)

    plm = bar.rd(NV_PJTAG_ACCESS_PRIV_LEVEL_MASK)
    write_prot = get_bits(plm, 7, 4)
    print(f'write_protection nibble = 0x{write_prot:x} '
          f'({"L3-only" if write_prot == 0x8 else "open" if write_prot == 0xF else "other"})')

    if len(sys.argv) > 1 and sys.argv[1] == 'read':
        chain_len = int(sys.argv[2]) if len(sys.argv) > 2 else 32
        cluster_sel = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        instr_id = int(sys.argv[4]) if len(sys.argv) > 4 else 0
        dword_len = (chain_len // 32) + (1 if chain_len % 32 else 0)
        try:
            data = jtag_read_seq(bar, chain_len, cluster_sel, instr_id, dword_len)
            print(f'read ok: {[hex(d) for d in data]}')
        except Host2JtagError as e:
            print(f'read failed: {e}')

    bar.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
