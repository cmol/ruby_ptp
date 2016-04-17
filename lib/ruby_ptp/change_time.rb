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
      builder.include '<sys/timex.h>'
      builder.include '<string.h>'
      builder.include '<signal.h>'
      builder.include '<unistd.h>'
      builder.include '<errno.h>'
      builder.add_compile_flags("-std=c99", "-lrt")

      builder.c '
int phase(long sec, long nsec) {
#ifndef ADJ_SETOFFSET
#define ADJ_SETOFFSET 0x0100
#endif
      // Clear clock for updating
      struct timex tx;
      int ret;
      //tx.modes = ADJ_STATUS;
      //tx.status = STA_PLL;
      //adjtimex(&tx);

      // Ready for time change
      tx.modes = ADJ_SETOFFSET | ADJ_NANO;

      tx.time.tv_sec  = sec;
      tx.time.tv_usec = nsec;
      /*if(tx.time.tv_usec < 0) {
        tx.time.tv_sec  -= 1;
        tx.time.tv_usec += 1000000000;
      }*/
      tx.status = tx.status & 0xffbf;

      ret = adjtimex(&tx);
      //ret = clock_adjtime(CLOCK_REALTIME,&tx);

      //if(ret < 0) {
      //  printf("%s\n", strerror(errno));
      //}

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
