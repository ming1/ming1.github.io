---
# You don't need to edit this file, it's empty on purpose.
# Edit theme's home layout instead if you wanna make some changes
# See: https://jekyllrb.com/docs/themes/#overriding-theme-defaults
layout: home
---

<header>
      <h1>{{ site.title | default: site.github.repository_name }}</h1>
      <h2>{{ site.description | default: site.github.project_tagline }}</h2>
</header>

<ul>
{% for post in site.posts %}
    <h3><a href="{{ post.url }}">{{ post.title }}</a></h3>
    <p><small><strong>{{ post.date | date: "%B %e, %Y" }}</strong> . {{ post.category }} . <a href="http://ming1.github.com{{ post.url }}#disqus_thread"></a></small></p>
{% endfor %}
</ul>
