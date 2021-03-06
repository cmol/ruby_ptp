require 'inline'

# Module for chaning the system time clock.
# Much of the code is derived from:
# https://github.com/johnstultz-work/timetests/blob/master/adj-setoffset.c

module RubyPtp
  class ChangeTime
    inline do |builder|
      builder.include '<stdio.h>'
      builder.include '<stdlib.h>'
      builder.include '<time.h>'
      builder.include '<sys/time.h>'
      builder.include '<sys/types.h>'
      builder.include '<sys/timex.h>'
      builder.include '<string.h>'
      builder.include '<signal.h>'
      builder.include '<unistd.h>'
      builder.include '<errno.h>'
      builder.include '<math.h>'
      builder.prefix <<-END
#define CLOCKFD 3
#define FD_TO_CLOCKID(fd)((~(clockid_t) (fd) << 3) | CLOCKFD)
END
      builder.add_compile_flags("-std=c99", "-lrt")

      builder.c '
int freq_adj(double adj, long clkid) {
  struct timex tx;
  int ret;
  if (clkid == 0) {
    memset(&tx, 0, sizeof(tx));
    clock_adjtime(CLOCK_REALTIME, &tx);
  }
  else {
    memset(&tx, 0, sizeof(tx));
    clock_adjtime(FD_TO_CLOCKID(clkid), &tx);
  }

  long curfreq = tx.freq;
  if(curfreq == 0) curfreq = -100;
  long tick    = tx.tick;
  printf("freq: %d\n", curfreq);
  printf("tick: %d\n", tick);

  curfreq += tick * 6553600;
  long long newfreq = (long long) (((double)curfreq) * adj);
  long newtick = 0;
  if (clkid == 0) {
    newtick = newfreq / 6553600;
    newfreq = newfreq % 6553600;
  }
  else {
    newfreq = curfreq + ((long) ((adj - 1) * 10000000));
    //newfreq = 0;
    //newtick = tick + ((long) ((adj - 1) * 10000000000));
  }
  printf("new freq: %d\n", newfreq);
  printf("new tick: %d\n", newtick);

  memset(&tx, 0, sizeof(tx));
  tx.tick = newtick;
  tx.freq = newfreq;
  if (clkid == 0) {
    tx.modes |= ADJ_FREQUENCY | ADJ_TICK;
    ret = clock_adjtime(CLOCK_REALTIME, &tx);
  }
  else {
    tx.modes |= ADJ_FREQUENCY;
    ret = clock_adjtime(FD_TO_CLOCKID(clkid), &tx);
  }

  if(ret < 0) {
    printf("%s\n", strerror(errno));
  }

  return ret;
}'

      builder.c '
int phase_adj(double adj, long clkid) {
  #ifndef ADJ_SETOFFSET
  #define ADJ_SETOFFSET 0x0100
  #endif

  struct timex tx;
  int ret;

  if (clkid == 0) {
    clkid = CLOCK_REALTIME;
  }
  else {
    clkid = FD_TO_CLOCKID(clkid);
  }

  // Do coarse time adjustment
  if (fabs(adj) > 0.00005) {
    struct timespec ts;
    int sec  = (int) adj;
    int nsec = (int) ((adj - sec) * 1000000000);
    printf("%d\n",nsec);
    //gettimeofday(&tv, 0);
    clock_gettime(clkid, &ts);
    ts.tv_sec  -= sec;
    ts.tv_nsec -= nsec;
    ret = clock_settime(clkid, &ts);
    //settimeofday(&tv, 0);
    return ret;
  }
  else {
    int sign = adj < 0 ? -1 : 1;
    int sec  = 0;
    int nsec = abs((int) (adj * 1000000000));

    // Fix adjust if we are adjusting the other way
    if (sign == -1) {
      sec   = -1;
      nsec += 1000000000;
    }

    tx.time.tv_sec =  sec;
    tx.time.tv_usec = nsec;

    tx.modes = ADJ_SETOFFSET | ADJ_NANO;
    ret = clock_adjtime(clkid, &tx);

    return ret;
  }
}'

      builder.c '
int phase(long sec, long nsec) {
#ifndef ADJ_SETOFFSET
#define ADJ_SETOFFSET 0x0100
#endif
      struct timex tx;
      int ret;

      // Ready for time change
      tx.modes = ADJ_SETOFFSET | ADJ_NANO;

      // If the error is more than 50 usec, do something
      // crude to get us close
      if (nsec > 50000) {
        struct timeval tv;
        gettimeofday(&tv, 0);
        tv.tv_sec -= sec;
        tv.tv_usec += ((sec < 0) ? nsec : nsec * -1) / 1000;
        settimeofday(&tv, 0);
        return 0;
      }

      tx.time.tv_sec  = sec * -1;
      tx.time.tv_usec = nsec;
      /*if(tx.time.tv_usec < 0) {
        tx.time.tv_sec  -= 1;
        tx.time.tv_usec += 1000000000;
      }*/
      // Try to clear a status
      tx.status = tx.status & 0xffbf;

      ret = adjtimex(&tx);
      //ret = clock_adjtime(CLOCK_REALTIME,&tx);

      if(ret < 0) {
        printf("%s\n", strerror(errno));
      }

      printf("%d\n", tx.status);

      return ret;
}'

      builder.c '
void clear() {
      struct timex tx;
      int ret;
      tx.modes = ADJ_STATUS;
      tx.status = STA_PLL;
      ret = adjtimex(&tx);
      /*if(ret < 0) {
        printf("%s\n", strerror(errno));
      } else {
        printf("%d\n", ret);
      }*/
      tx.modes = ADJ_STATUS;
      tx.status = 0;
      ret = adjtimex(&tx);
      /*if(ret < 0) {
        printf("%s\n", strerror(errno));
      } else {
        printf("%d\n", ret);
      }*/
}'

    builder.c '
double get() { 
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  //time(&now);
  double sec, nsec;
  sec  = (double) now.tv_sec;
  nsec = (double) now.tv_nsec;
  sec  = sec + (nsec / 1000000000.0);
  printf("%f\n",nsec);
  printf("%f\n",nsec / 1000000000.0);
  return sec;
}'

    builder.c <<-'SRC'
     static VALUE gett(VALUE arr) {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);

        VALUE* array = RARRAY_PTR(arr);
        array[0] = INT2NUM(now.tv_sec);
        array[1] = INT2NUM(now.tv_nsec);

        return arr;
    }
    SRC

    end
  end
end
