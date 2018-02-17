clean:
	find ./ -name "*~" | xargs rm -f

#ouch : ouch.c
#	${CC} -o $@ ouch.c ${CFLAGS} ${LDLIBS}
