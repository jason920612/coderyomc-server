#!/usr/bin/env python3
# 2-bit ADD-accumulator: real build-08 ripple adder computes ACC+operand (with carry),
# 2-bit master-slave register (FF0=bit0, FF1=bit1) latches SUM each clock.
# ACC := (ACC + operand) mod 4.  Register Q feeds adder A (feedback), operand feeds adder B.
import sys, drv, adder
from ff import FF
R=drv.R
F0=FF(0,190)   # bit0 register: Q0=(44,101,312)
F1=FF(80,190)  # bit1 register: Q1=(124,101,312)

def read_acc():
    return F0.q() + (F1.q()<<1)

def clock_both(settle=30):
    drv.sprint(settle)
    F0.setcells(F0.MasterE(),True);  F1.setcells(F1.MasterE(),True);  drv.sprint(14)
    F0.setcells(F0.MasterE(),False); F1.setcells(F1.MasterE(),False); drv.sprint(14)
    F0.setcells(F0.SlaveE(),True);   F1.setcells(F1.SlaveE(),True);   drv.sprint(14)
    F0.setcells(F0.SlaveE(),False);  F1.setcells(F1.SlaveE(),False);  drv.sprint(20)

def reset_acc0():
    # break power-on metastability -> define ACC=0
    F0.setD(0); F1.setD(0)
    clock_both(); clock_both()
    return read_acc()

def step(operand):
    acc = read_acc()
    # drive adder: A = ACC (feedback), B = operand
    adder.drive(acc, operand); drv.sprint(80)
    r = adder.read()
    s0, s1 = r['S0'], r['S1']       # 2-bit SUM (mod 4); Cout1 = overflow beyond bit1
    summ = s0 + (s1<<1)
    # latch SUM into the register
    F0.setD(s0); F1.setD(s1)
    clock_both()
    newacc = read_acc()
    return dict(acc_in=acc, op=operand, sum_add=summ, cout=r['Cout1'], acc_out=newacc,
                ok=(newacc==((acc+operand)&3)))

if __name__=="__main__":
    prog=[int(x) for x in sys.argv[1:]] or [1,1,2,1]
    a=reset_acc0(); print(f"reset ACC={a}")
    for op in prog:
        st=step(op)
        print(f"  ACC {st['acc_in']} + op {st['op']} = {st['sum_add']} (cout={st['cout']}) -> ACC {st['acc_out']}  {'OK' if st['ok'] else 'DIVERGE'}")
    R.close()
