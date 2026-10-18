-- Course content, class schedules, progress, and activity submissions.
-- Apply after the initial identity/course schema has been created in Supabase.

create table if not exists public.course_modules (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null,
  description text not null default '',
  position integer not null default 0,
  is_published boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.course_modules(id) on delete cascade,
  title text not null,
  content_text text not null default '',
  video_url text,
  material_url text,
  activity_prompt text not null default '',
  position integer not null default 0,
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes > 0),
  is_published boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Each class gets its own release and due dates for the lessons in its course.
create table if not exists public.class_lesson_schedule (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.course_classes(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  scheduled_order integer not null default 0,
  available_at timestamptz not null,
  due_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint class_lesson_schedule_class_lesson_unique unique (class_id, lesson_id),
  constraint class_lesson_schedule_due_after_available check (due_at is null or due_at >= available_at)
);

create table if not exists public.lesson_progress (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  status text not null default 'not_started'
    check (status in ('not_started', 'in_progress', 'completed')),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint lesson_progress_enrollment_lesson_unique unique (enrollment_id, lesson_id),
  constraint lesson_progress_completion_consistent check (
    (status = 'completed' and completed_at is not null)
    or (status <> 'completed')
  )
);

create table if not exists public.activity_submissions (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  response_text text not null,
  status text not null default 'submitted'
    check (status in ('submitted', 'reviewed', 'needs_revision')),
  feedback text,
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists course_modules_course_position_idx
  on public.course_modules(course_id, position);
create index if not exists lessons_module_position_idx
  on public.lessons(module_id, position);
create index if not exists class_lesson_schedule_class_order_idx
  on public.class_lesson_schedule(class_id, scheduled_order);
create index if not exists lesson_progress_enrollment_status_idx
  on public.lesson_progress(enrollment_id, status);
create index if not exists activity_submissions_enrollment_submitted_idx
  on public.activity_submissions(enrollment_id, submitted_at desc);

-- SECURITY DEFINER helpers avoid recursive RLS checks when checking enrollment
-- and enforce release prerequisites in the database, not just in the browser.
create or replace function public.is_active_student_in_class(p_class_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.enrollments e
    where e.class_id = p_class_id
      and e.student_id = auth.uid()
      and e.status = 'active'
  );
$$;

create or replace function public.can_access_scheduled_lesson(
  p_class_id uuid,
  p_lesson_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_active_student_in_class(p_class_id)
    and exists (
      select 1
      from public.class_lesson_schedule current_schedule
      join public.lessons current_lesson on current_lesson.id = current_schedule.lesson_id
      join public.course_modules current_module on current_module.id = current_lesson.module_id
      join public.course_classes current_class
        on current_class.id = current_schedule.class_id
       and current_class.course_id = current_module.course_id
      where current_schedule.class_id = p_class_id
        and current_schedule.lesson_id = p_lesson_id
        and current_schedule.available_at <= now()
        and current_lesson.is_published = true
        and current_module.is_published = true
        and not exists (
          select 1
          from public.class_lesson_schedule previous_schedule
          join public.lessons previous_lesson on previous_lesson.id = previous_schedule.lesson_id
          join public.course_modules previous_module on previous_module.id = previous_lesson.module_id
          where previous_schedule.class_id = p_class_id
            and previous_schedule.scheduled_order < current_schedule.scheduled_order
            and previous_schedule.due_at < now()
            and previous_module.is_published = true
            and previous_lesson.is_published = true
            and not exists (
              select 1
              from public.lesson_progress lp
              join public.enrollments e on e.id = lp.enrollment_id
              where e.student_id = auth.uid()
                and e.class_id = p_class_id
                and e.status = 'active'
                and lp.lesson_id = previous_schedule.lesson_id
                and lp.status = 'completed'
            )
        )
    );
$$;

grant execute on function public.is_active_student_in_class(uuid) to authenticated;
grant execute on function public.can_access_scheduled_lesson(uuid, uuid) to authenticated;

alter table public.course_modules enable row level security;
alter table public.lessons enable row level security;
alter table public.class_lesson_schedule enable row level security;
alter table public.lesson_progress enable row level security;
alter table public.activity_submissions enable row level security;

-- Modules: administrators and assigned teachers manage content; enrolled students read published content.
drop policy if exists course_modules_read_authorized on public.course_modules;
create policy course_modules_read_authorized on public.course_modules
for select to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.course_classes cc
    where cc.course_id = course_modules.course_id
      and public.is_teacher_of_class(cc.id)
  )
  or (
    is_published = true
    and exists (
      select 1
      from public.course_classes cc
      where cc.course_id = course_modules.course_id
        and public.is_active_student_in_class(cc.id)
    )
  )
);

drop policy if exists course_modules_manage_authorized on public.course_modules;
create policy course_modules_manage_authorized on public.course_modules
for all to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.course_classes cc
    where cc.course_id = course_modules.course_id
      and public.is_teacher_of_class(cc.id)
  )
)
with check (
  public.is_admin()
  or exists (
    select 1 from public.course_classes cc
    where cc.course_id = course_modules.course_id
      and public.is_teacher_of_class(cc.id)
  )
);

-- Lessons: students can read only released lessons whose overdue prerequisites are complete.
drop policy if exists lessons_read_authorized on public.lessons;
create policy lessons_read_authorized on public.lessons
for select to authenticated
using (
  public.is_admin()
  or exists (
    select 1
    from public.course_modules m
    join public.course_classes cc on cc.course_id = m.course_id
    where m.id = lessons.module_id
      and public.is_teacher_of_class(cc.id)
  )
  or exists (
    select 1
    from public.course_modules m
    join public.course_classes cc on cc.course_id = m.course_id
    where m.id = lessons.module_id
      and public.can_access_scheduled_lesson(cc.id, lessons.id)
  )
);

drop policy if exists lessons_manage_authorized on public.lessons;
create policy lessons_manage_authorized on public.lessons
for all to authenticated
using (
  public.is_admin()
  or exists (
    select 1
    from public.course_modules m
    join public.course_classes cc on cc.course_id = m.course_id
    where m.id = lessons.module_id
      and public.is_teacher_of_class(cc.id)
  )
)
with check (
  public.is_admin()
  or exists (
    select 1
    from public.course_modules m
    join public.course_classes cc on cc.course_id = m.course_id
    where m.id = lessons.module_id
      and public.is_teacher_of_class(cc.id)
  )
);

-- Class-specific schedule is visible to admins, assigned teachers, and eligible students.
drop policy if exists class_lesson_schedule_read_authorized on public.class_lesson_schedule;
create policy class_lesson_schedule_read_authorized on public.class_lesson_schedule
for select to authenticated
using (
  public.is_admin()
  or public.is_teacher_of_class(class_id)
  or public.can_access_scheduled_lesson(class_id, lesson_id)
);

drop policy if exists class_lesson_schedule_manage_authorized on public.class_lesson_schedule;
create policy class_lesson_schedule_manage_authorized on public.class_lesson_schedule
for all to authenticated
using (public.is_admin() or public.is_teacher_of_class(class_id))
with check (public.is_admin() or public.is_teacher_of_class(class_id));

-- Progress: students manage their own progress; teachers see students assigned to them.
drop policy if exists lesson_progress_read_authorized on public.lesson_progress;
create policy lesson_progress_read_authorized on public.lesson_progress
for select to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and e.student_id = auth.uid()
  )
  or exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and public.is_teacher_of_student(e.student_id)
  )
);

drop policy if exists lesson_progress_insert_own on public.lesson_progress;
create policy lesson_progress_insert_own on public.lesson_progress
for insert to authenticated
with check (
  exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and e.student_id = auth.uid()
      and e.status = 'active'
  )
  and exists (
    select 1 from public.class_lesson_schedule s
    where s.lesson_id = lesson_progress.lesson_id
      and public.can_access_scheduled_lesson(s.class_id, lesson_progress.lesson_id)
  )
);

drop policy if exists lesson_progress_update_own on public.lesson_progress;
create policy lesson_progress_update_own on public.lesson_progress
for update to authenticated
using (
  exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and e.student_id = auth.uid()
      and e.status = 'active'
  )
)
with check (
  exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and e.student_id = auth.uid()
      and e.status = 'active'
  )
);

drop policy if exists lesson_progress_manage_authorized on public.lesson_progress;
create policy lesson_progress_manage_authorized on public.lesson_progress
for all to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and public.is_teacher_of_student(e.student_id)
  )
)
with check (
  public.is_admin()
  or exists (
    select 1 from public.enrollments e
    where e.id = lesson_progress.enrollment_id
      and public.is_teacher_of_student(e.student_id)
  )
);

-- Activity submissions: students submit their own answers; admins/assigned teachers review them.
drop policy if exists activity_submissions_read_authorized on public.activity_submissions;
create policy activity_submissions_read_authorized on public.activity_submissions
for select to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.enrollments e
    where e.id = activity_submissions.enrollment_id
      and e.student_id = auth.uid()
  )
  or exists (
    select 1 from public.enrollments e
    where e.id = activity_submissions.enrollment_id
      and public.is_teacher_of_student(e.student_id)
  )
);

drop policy if exists activity_submissions_insert_own on public.activity_submissions;
create policy activity_submissions_insert_own on public.activity_submissions
for insert to authenticated
with check (
  status = 'submitted'
  and reviewed_by is null
  and reviewed_at is null
  and exists (
    select 1 from public.enrollments e
    where e.id = activity_submissions.enrollment_id
      and e.student_id = auth.uid()
      and e.status = 'active'
  )
  and exists (
    select 1 from public.class_lesson_schedule s
    where s.lesson_id = activity_submissions.lesson_id
      and public.can_access_scheduled_lesson(s.class_id, activity_submissions.lesson_id)
  )
);

drop policy if exists activity_submissions_review_authorized on public.activity_submissions;
create policy activity_submissions_review_authorized on public.activity_submissions
for update to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.enrollments e
    where e.id = activity_submissions.enrollment_id
      and public.is_teacher_of_student(e.student_id)
  )
)
with check (
  public.is_admin()
  or exists (
    select 1 from public.enrollments e
    where e.id = activity_submissions.enrollment_id
      and public.is_teacher_of_student(e.student_id)
  )
);

comment on table public.course_modules is 'Modules for reusable courses.';
comment on table public.lessons is 'Lesson content for a course module.';
comment on table public.class_lesson_schedule is 'Per-class release schedule, supporting lesson prerequisites.';
comment on table public.lesson_progress is 'Per-enrollment progress for each lesson.';
comment on table public.activity_submissions is 'Student activity responses and teacher feedback.';
