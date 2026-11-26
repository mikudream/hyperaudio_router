#!/system/bin/sh
# Property publication runs in late-start service. Calling setprop from a
# blocking post-fs-data hook can stall Android init on some root managers.
exit 0
