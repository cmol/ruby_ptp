require 'inline'

module RubyPtp
  class InitInterface
    inline do |builder|
      builder.include '<stdio.h>'
      builder.include '<stdlib.h>'
      builder.include '<errno.h>'
      builder.include '<string.h>'
      builder.include '<sys/socket.h>'
      builder.include '<sys/select.h>'
      builder.include '<sys/ioctl.h>'
      builder.include '<arpa/inet.h>'
      builder.include '<net/if.h>'
      builder.include '<asm/types.h>'
      builder.include '<linux/net_tstamp.h>'
      builder.include '<linux/errqueue.h>'

      builder.c '
int hwstamp()
{
  int so_timestamping_flags = 0;
  int so_timestamp = 0;
  int so_timestampns = 0;
  int siocgstamp = 0;
  int siocgstampns = 0;
  int ip_multicast_loop = 0;
  char *interface;
  int i;
  int enabled = 1;
  int sock;
  struct ifreq device;
  struct ifreq hwtstamp;
  struct hwtstamp_config hwconfig, hwconfig_requested;
  struct sockaddr_in addr;
  struct ip_mreq imr;
  struct in_addr iaddr;
  int val;
  socklen_t len;
  struct timeval next;

  interface = "eth0";

  sock = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (sock < 0) {
    printf("socket failed");
    return 1;
  }

  memset(&device, 0, sizeof(device));
  strncpy(device.ifr_name, interface, sizeof(device.ifr_name));
  if (ioctl(sock, SIOCGIFADDR, &device) < 0) {
    printf("getting interface IP address");
    return 1;
  }

  memset(&hwtstamp, 0, sizeof(hwtstamp));
  strncpy(hwtstamp.ifr_name, interface, sizeof(hwtstamp.ifr_name));
  hwtstamp.ifr_data = (void *)&hwconfig;
  memset(&hwconfig, 0, sizeof(hwconfig));
  hwconfig.tx_type = HWTSTAMP_TX_ON;
  hwconfig.rx_filter =
    (so_timestamping_flags & SOF_TIMESTAMPING_RX_HARDWARE) ?
    HWTSTAMP_FILTER_PTP_V1_L4_SYNC : HWTSTAMP_FILTER_NONE;
  hwconfig_requested = hwconfig;
  if (ioctl(sock, 0x89b0, &hwtstamp) < 0) {
    if ((errno == EINVAL || errno == ENOTSUP) &&
        hwconfig_requested.tx_type == HWTSTAMP_TX_OFF &&
        hwconfig_requested.rx_filter == HWTSTAMP_FILTER_NONE)
      printf("SIOCSHWTSTAMP: disabling hardware time stamping not possible\n");
    else {
      printf("SIOCSHWTSTAMP");
      return 1;
    }
  }
  printf("SIOCSHWTSTAMP: tx_type %d requested, got %d; rx_filter %d requested, got %d\n",
         hwconfig_requested.tx_type, hwconfig.tx_type,
         hwconfig_requested.rx_filter, hwconfig.rx_filter);

  return sock;
}'
    end
  end

end
