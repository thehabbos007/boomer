#version 130
in vec3 aPos;
in vec2 aTexCoord;
out vec2 texcoord;
uniform mat4 transform;
void main()
{
	gl_Position = transform * vec4(aPos, 1.0f);
	texcoord = aTexCoord;
}
