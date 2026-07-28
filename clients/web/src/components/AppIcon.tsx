import {
  ArrowDown,
  ArrowLeft,
  ArrowUpRight,
  AtSign,
  Bell,
  Bookmark,
  Camera,
  CameraOff,
  Check,
  ChevronDown,
  ChevronLeft,
  Circle,
  ContactRound,
  Copy,
  Download,
  ExternalLink,
  FileText,
  Filter,
  Flag,
  Hash,
  LogIn,
  LogOut,
  LoaderCircle,
  Menu,
  Maximize2,
  MessageCircle,
  MessagesSquare,
  Mic,
  MicOff,
  Minimize2,
  MoreHorizontal,
  Paperclip,
  Phone,
  PhoneOff,
  Plus,
  RefreshCw,
  Reply,
  Search,
  ScreenShare,
  ScreenShareOff,
  Send,
  Share,
  SlidersHorizontal,
  Sparkles,
  TriangleAlert,
  Trash2,
  UserPlus,
  UserRound,
  UsersRound,
  Video,
  VideoOff,
  X,
  type LucideProps
} from "lucide-react";

const icons = {
  arrowDown: ArrowDown,
  arrowLeft: ArrowLeft,
  arrowUpRight: ArrowUpRight,
  atSign: AtSign,
  bell: Bell,
  bookmark: Bookmark,
  camera: Camera,
  cameraOff: CameraOff,
  check: Check,
  chevronDown: ChevronDown,
  chevronLeft: ChevronLeft,
  circle: Circle,
  contact: ContactRound,
  copy: Copy,
  download: Download,
  externalLink: ExternalLink,
  file: FileText,
  filter: Filter,
  flag: Flag,
  hash: Hash,
  logIn: LogIn,
  logOut: LogOut,
  loader: LoaderCircle,
  menu: Menu,
  maximize: Maximize2,
  message: MessageCircle,
  messages: MessagesSquare,
  mic: Mic,
  micOff: MicOff,
  minimize: Minimize2,
  more: MoreHorizontal,
  paperclip: Paperclip,
  phone: Phone,
  phoneOff: PhoneOff,
  plus: Plus,
  refresh: RefreshCw,
  reply: Reply,
  search: Search,
  screenShare: ScreenShare,
  screenShareOff: ScreenShareOff,
  send: Send,
  share: Share,
  sliders: SlidersHorizontal,
  sparkles: Sparkles,
  triangleAlert: TriangleAlert,
  trash: Trash2,
  user: UserRound,
  userPlus: UserPlus,
  users: UsersRound,
  video: Video,
  videoOff: VideoOff,
  x: X
} as const;

export type AppIconName = keyof typeof icons;

type AppIconProps = Omit<LucideProps, "ref"> & {
  name: AppIconName;
};

export function AppIcon({ className = "", name, ...props }: AppIconProps) {
  const Icon = icons[name];
  const accessible = Boolean(props["aria-label"]);

  return (
    <Icon
      className={`app-icon ${className}`.trim()}
      aria-hidden={accessible ? undefined : true}
      role={accessible ? "img" : undefined}
      focusable="false"
      {...props}
    />
  );
}
