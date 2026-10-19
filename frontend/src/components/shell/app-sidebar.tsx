import type { ReactNode } from 'react';
import { useRouterState } from '@tanstack/react-router';
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar';
import { visibleGroups } from './navigation';

export function AppSidebar({
  isAdmin,
  counts = {},
  footer,
}: {
  isAdmin: boolean;
  /** A number beside a screen's name, by href: what is waiting there. */
  counts?: Record<string, number | undefined>;
  footer?: ReactNode;
}) {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const { isMobile, setOpenMobile } = useSidebar();
  // On the phone the menu is a sheet over the screen; choosing a screen
  // should show it, not leave the sheet in the way.
  const close = () => {
    if (isMobile) setOpenMobile(false);
  };
  return (
    <Sidebar collapsible="offcanvas">
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton size="lg" render={<a href="/" />}>
              <span className="flex size-8 items-center justify-center rounded-lg bg-primary text-primary-foreground">
                <KeepardMark />
              </span>
              <span className="font-semibold tracking-tight">Keepard</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>
      <SidebarContent>
        {visibleGroups(isAdmin).map((group) => (
          <SidebarGroup key={group.label}>
            <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {group.items.map(({ href, label, icon: Icon }) => (
                  <SidebarMenuItem key={href}>
                    <SidebarMenuButton
                      isActive={pathname === href}
                      render={
                        <a
                          href={href}
                          onClick={close}
                          aria-current={pathname === href ? 'page' : undefined}
                        />
                      }
                    >
                      <Icon />
                      <span>{label}</span>
                    </SidebarMenuButton>
                    {counts[href] ? (
                      <SidebarMenuBadge className="rounded-full bg-primary/10 text-primary">
                        {counts[href]}
                      </SidebarMenuBadge>
                    ) : null}
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ))}
      </SidebarContent>
      <SidebarFooter>{footer}</SidebarFooter>
    </Sidebar>
  );
}

/**
 * The Keepard safe, drawn in the tile's own text colour so it follows the
 * theme. The same drawing as public/icon.svg and site/brand/.
 */
function KeepardMark() {
  return (
    <svg viewBox="0 0 64 64" className="size-5" aria-hidden="true">
      <g fill="none" stroke="currentColor" strokeLinecap="round">
        <rect x="8.5" y="9" width="47" height="40" rx="8" strokeWidth="5" />
        <circle cx="26" cy="29" r="8" strokeWidth="4.5" />
        <path d="M44 21.5 V36.5" strokeWidth="5" />
      </g>
      <g fill="currentColor">
        <rect x="14" y="50" width="9" height="6" rx="1.5" />
        <rect x="41" y="50" width="9" height="6" rx="1.5" />
        <circle cx="26" cy="29" r="2.2" />
      </g>
    </svg>
  );
}
