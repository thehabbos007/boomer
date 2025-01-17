import os

import navigation
import image
import config

import x11/xlib, x11/x, x11/xutil
import opengl, opengl/glx
import la

const
  isDebug = not (defined(danger) or defined(release))
  vertexShader = slurp "boomer.vs"
  fragmentShader = slurp "boomer.fs"

proc newShader(shader: string, kind: GLenum, filePath: string): GLuint =
  result = glCreateShader(kind)
  var shaderArray = allocCStringArray([shader])
  glShaderSource(result, 1, shaderArray, nil)
  glCompileShader(result)
  deallocCStringArray(shaderArray)
  when isDebug:
    var success: GLint
    var infoLog = newString(512).cstring
    glGetShaderiv(result, GL_COMPILE_STATUS, addr success)
    if not success.bool:
      glGetShaderInfoLog(result, 512, nil, infoLog)
      echo "------------------------------"
      echo "Error during compiling shader: ", filePath, ". Log:"
      echo infoLog
      echo "------------------------------"

proc newShaderProgram(vertex, fragment: string): GLuint =
  result = glCreateProgram()

  # TODO(#41): filename for shader compilation error reporting are hardcoded
  var
    vertexShader = newShader(vertex, GL_VERTEX_SHADER, "boomer.vs")
    fragmentShader = newShader(fragment, GL_FRAGMENT_SHADER, "boomer.fs")

  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)

  glLinkProgram(result)

  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)

  when isDebug:
    var success: GLint
    var infoLog = newString(512).cstring
    glGetProgramiv(result, GL_LINK_STATUS, addr success)
    if not success.bool:
      glGetProgramInfoLog(result, 512, nil, infoLog)
      echo infoLog

  glUseProgram(result)

proc draw(screenshot: Image, camera: var Camera, shader, vao, texture: GLuint) =
  glClearColor(0.1, 0.1, 0.1, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

  glUseProgram(shader)

  glUniformMatrix4fv(glGetUniformLocation(shader, "transform".cstring), 1, false, camera.matrix.caddr)

  glBindVertexArray(vao)
  glDrawElements(GL_TRIANGLES, count = 6, GL_UNSIGNED_INT, indices = nil)

# TODO(#29): get rid of custom X11 button constants
const
  LEFT_BUTTON = 1
  WHEEL_UP = 4
  WHEEL_DOWN = 5

proc main() =
  var config = defaultConfig
  let configFile = block:
    if paramCount() > 0:
      paramStr(1)
    else:
      getConfigDir() / "boomer" / "config"

  if existsFile configFile:
    config = loadConfig(configFile)
  else:
    stderr.writeLine configFile & " doesn't exist. Using default values. "

  echo "Using config: ", config

  # Fetching pixel data from X

  var display = XOpenDisplay(nil)
  if display == nil:
    quit "Failed to open display"
  defer:
    discard XCloseDisplay(display)

  var root = DefaultRootWindow(display)

  var screenshot = takeScreenshot(display, root)
  assert screenshot.bpp == 32

  let screen = XDefaultScreen(display)
  var glxMajor, glxMinor: int

  if (not glXQueryVersion(display, glxMajor, glxMinor) or
      (glxMajor == 1 and glxMinor < 3) or
      (glxMajor < 1)):
    quit "Invalid GLX version. Expected >=1.3"
  echo("GLX version ", glxMajor, ".", glxMinor)
  echo("GLX extension: ", glXQueryExtensionsString(display, screen))

  var attrs = [
    GLX_RGBA,
    GLX_DEPTH_SIZE, 24,
    GLX_DOUBLEBUFFER,
    None
  ]

  var vi = glXChooseVisual(display, 0, addr attrs[0])
  if vi == nil:
    quit "No appropriate visual found"

  echo "Visual ", vi.visualid, " selected"
  var swa: TXSetWindowAttributes
  swa.colormap = XCreateColormap(display, root,
                                 vi.visual, AllocNone)
  swa.event_mask = ButtonPressMask or ButtonReleaseMask or KeyPressMask or
                   PointerMotionMask or ExposureMask or ClientMessage

  # TODO(#8): the window should be the size of the screen
  var win = XCreateWindow(
    display, root,
    0, 0, screenshot.width.cuint, screenshot.height.cuint, 0,
    vi.depth, InputOutput, vi.visual,
    CWColormap or CWEventMask, addr swa)

  discard XMapWindow(display, win)

  var wmName = "boomer"
  var wmClass = "Boomer"
  var hints = TXClassHint(res_name: wmName, res_class: wmClass)
  
  discard XStoreName(display, win, wmName)
  discard XSetClassHint(display, win, addr(hints))

  var wmDeleteMessage = XInternAtom(
    display, "WM_DELETE_WINDOW",
    false.TBool)

  discard XSetWMProtocols(display, win,
                          addr wmDeleteMessage, 1)

  var glc = glXCreateContext(display, vi, nil, GL_TRUE)
  discard glXMakeCurrent(display, win, glc)

  loadExtensions()

  var shaderProgram = newShaderProgram(vertexShader, fragmentShader)

  var
    vao, vbo, ebo: GLuint
    vertices = [
      # Position                 Texture coords
      [GLfloat  1.0,  -1.0, 0.0, 1.0, 1.0], # Top right
      [GLfloat  1.0,  1.0,  0.0, 1.0, 0.0], # Bottom right
      [GLfloat -1.0,  1.0,  0.0, 0.0, 0.0], # Bottom left
      [GLfloat -1.0,  -1.0, 0.0, 0.0, 1.0]  # Top left
    ]
    indices = [GLuint(0), 1, 3,
                      1,  2, 3]

  glGenVertexArrays(1, addr vao)
  glGenBuffers(1, addr vbo)
  glGenBuffers(1, addr ebo)
  defer:
    glDeleteVertexArrays(1, addr vao)
    glDeleteBuffers(1, addr vbo)
    glDeleteBuffers(1, addr ebo)

  glBindVertexArray(vao)

  glBindBuffer(GL_ARRAY_BUFFER, vbo)
  glBufferData(GL_ARRAY_BUFFER, size = GLsizeiptr(sizeof(vertices)),
               addr vertices, GL_STATIC_DRAW)

  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, size = GLsizeiptr(sizeof(indices)),
               addr indices, GL_STATIC_DRAW);

  var stride = GLsizei(vertices[0].len * sizeof(GLfloat))

  glVertexAttribPointer(0, 3, cGL_FLOAT, false, stride, cast[pointer](0))
  glEnableVertexAttribArray(0)

  glVertexAttribPointer(1, 2, cGL_FLOAT, false, stride, cast[pointer](3 * sizeof(GLfloat)))
  glEnableVertexAttribArray(1)

  var texture = 0.GLuint
  glGenTextures(1, addr texture)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, texture)

  glTexImage2D(GL_TEXTURE_2D,
               0,
               GL_RGB.GLint,
               screenshot.width,
               screenshot.height,
               0,
               # TODO(#13): the texture format is hardcoded
               GL_BGRA,
               GL_UNSIGNED_BYTE,
               screenshot.pixels)
  glGenerateMipmap(GL_TEXTURE_2D)

  glUniform1i(glGetUniformLocation(shaderProgram, "tex".cstring), 0)


  glEnable(GL_TEXTURE_2D)

  glOrtho(0.0, screenshot.width.float,
          screenshot.height.float, 0.0,
          -1.0, 1.0)

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)

  glViewport(0, 0, screenshot.width, screenshot.height)

  var
    quitting = false
    camera = Camera(scale: 1.0, matrix: mat4f(1))
    mouse: Mouse

  while not quitting:
    var wa: TXWindowAttributes
    discard XGetWindowAttributes(display, win, addr wa)

    var xev: TXEvent
    while XPending(display) > 0:
      discard XNextEvent(display, addr xev)
      case xev.theType
      of Expose:
        discard

      of MotionNotify:
        mouse.curr = vec2(xev.xmotion.x.float32 / screenshot.width.float32 * 2.0'f32 - 1.0'f32,
                          xev.xmotion.y.float32 / screenshot.height.float32 * 2.0'f32 - 1.0'f32)

        if mouse.drag:
          let mouseDelta = mouse.prev - mouse.curr
          camera.position += mouseDelta
          camera.velocity = mouseDelta * config.dragVelocityFactor
          mouse.prev = mouse.curr

      of ClientMessage:
        if cast[TAtom](xev.xclient.data.l[0]) == wmDeleteMessage:
          quitting = true

      of KeyPress:
        case xev.xkey.keycode
        of 19:
          camera.scale = 1.0
          camera.deltaScale = 0.0
          camera.position = vec2(0.0'f32, 0.0)
          camera.velocity = vec2(0.0'f32, 0.0)
        of 24:
          quitting = true
        of 27:
          if configFile.len > 0 and existsFile(configFile):
            config = loadConfig(configFile)
        else:
          discard

      of ButtonPress:
        case xev.xbutton.button
        of LEFT_BUTTON:
          mouse.prev = mouse.curr
          mouse.drag = true

        of WHEEL_UP:
          camera.deltaScale += config.scrollSpeed

        of WHEEL_DOWN:
          camera.deltaScale -= config.scrollSpeed

        else:
          discard

      of ButtonRelease:
        case xev.xbutton.button
        of LEFT_BUTTON:
          mouse.drag = false
        else:
          discard
      else:
        discard

    camera.update(config, 1.0 / config.fps.float, mouse)

    screenshot.draw(camera, shaderProgram, vao, texture)

    glXSwapBuffers(display, win)

main()
